#!/usr/bin/env bash
#
# Upload, purge, read back, and put the previous repository back if what is served is not what was uploaded.
#
#   publish.sh --tree <dir> --pages <dir> --previous <dir> --public-key <file> --bucket <name> --url <base> [--extra <file>] [--now <time>]
#
# <tree> is what the signer left, as the job downloaded it: regular files of arch/x86_64 and nothing else (no link, no folder, no
# page, no key that came with it). <pages> is what this job built, in a folder of its own: the key, the index page and the
# installers. The two are copied into a third folder, and that is what is uploaded, purged and read back.
#
# The R2 credentials and the purge token are in the environment (see sync-archive.sh and purge-cache.sh). The order is
# the one of sync-archive.sh; this script adds the reading back that closes it. A repository that is cut (an upload that
# failed, a purge that did not take, a copy served from the edge that is not the one written) is not left as it is:
# the previous database group is written again, the edge purged, and the run fails, so a red run means the repository
# is either the new one, whole, or the one before. The packages a publication retired are deleted last, once what is served has
# been read back.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tree="" pages="" previous="" pub="" bucket="" url="" extra=""
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::publish.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--tree) tree="$2" ;;
		--pages) pages="$2" ;;
		--previous) previous="$2" ;;
		--public-key) pub="$2" ;;
		--bucket) bucket="$2" ;;
		--url) url="$2" ;;
		--extra) extra="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::publish.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$tree" ] || [ -z "$pages" ] || [ -z "$previous" ] || [ -z "$pub" ] || [ -z "$bucket" ] || [ -z "$url" ]; then
	echo "::error::usage: publish.sh --tree <dir> --pages <dir> --previous <dir> --public-key <file> --bucket <name> --url <base>" >&2
	exit 2
fi
# 0. What the job downloaded holds only the signed files, and what it built goes in beside them in a folder that is new.
[ -d "$tree/arch/x86_64" ] || { echo "::error::$tree has no arch/x86_64" >&2; exit 1; }
if [ -n "$(find "$tree" -mindepth 1 ! -type d ! -type f)" ] || [ -n "$(find "$tree" -type f -links +1)" ]; then
	echo "::error::the signed tree holds something that is not a regular file with one link; nothing is uploaded" >&2
	exit 1
fi
if [ -n "$(find "$tree" -mindepth 1 -type d ! -path "$tree/arch" ! -path "$tree/arch/x86_64")" ] \
	|| [ -n "$(find "$tree" -mindepth 1 -type f ! -path "$tree/arch/x86_64/*")" ]; then
	echo "::error::the signed tree holds a folder or a file outside arch/x86_64 (a page, a key, an installer); those are built by this job, not received; nothing is uploaded" >&2
	exit 1
fi
if [ -n "$(find "$pages" -mindepth 1 ! -type f ! -type d)" ] || [ -n "$(find "$pages" -mindepth 1 -type f ! -name glyndor-pacman-key.asc ! -name index.html ! -path "$pages/install/*")" ]; then
	echo "::error::$pages holds more than the key, the index page and the installers, or something that is not a regular file" >&2
	exit 1
fi
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -r --no-dereference "$tree/arch" "$stage/arch"
cp -r --no-dereference "$pages/." "$stage/"
purge=(bash "$HERE/scripts/publish/purge-cache.sh" --url "$url" --tree "$stage")
[ -z "$extra" ] || purge+=(--extra "$extra")

# 1. The upload restores by itself when the write of the database group fails. Any other failure, one that came after writes
# included, falls to the same restore below, with the edge purged.
ok=yes
rc=0
bash "$HERE/scripts/publish/sync-archive.sh" --tree "$stage" --previous "$previous" --public-key "$pub" --bucket "$bucket" --now "$now" || rc=$?
if [ "$rc" -eq 5 ]; then
	# Refused before the first write: the bucket is as it was, and there is nothing to put back or to purge.
	echo "::error::the upload was refused before anything was written" >&2
	exit 1
fi
[ "$rc" -eq 0 ] || ok=no

# 2. The edge, and what it serves now.
if [ "$ok" = yes ]; then
	"${purge[@]}" || ok=no
fi
if [ "$ok" = yes ]; then
	bash "$HERE/scripts/publish/verify-published.sh" --url "$url" --tree "$stage" --public-key "$pub" --now "$now" \
		--attempts "${VERIFY_ATTEMPTS:-6}" --delay "${VERIFY_DELAY:-10}" --deep || ok=no
fi
if [ "$ok" = yes ]; then
	# The cleanup comes after the read back; it keeps every retired package, because a signed database that a client could
	# still hold names it, and says which.
	if ! bash "$HERE/scripts/publish/sync-archive.sh" --cleanup --tree "$stage" --bucket "$bucket" --now "$now"; then
		echo "::error::published and read back, but the cleanup of retired packages failed" >&2
		exit 1
	fi
	echo "published, and read back from $url"
	exit 0
fi

# 3. Not what was uploaded: the previous group goes back, and the edge is told.
echo "::error::what is served is not what was published; putting the previous repository back" >&2
bash "$HERE/scripts/publish/sync-archive.sh" --restore --previous "$previous" --tree "$stage" --public-key "$pub" --bucket "$bucket" || true
"${purge[@]}" || true
exit 1
