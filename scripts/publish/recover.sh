#!/usr/bin/env bash
#
# Put back the repository a publication left half written, from what that run kept, and read it back.
#
#   recover.sh --tree <dir> --previous <dir> --public-key <file> --bucket <name> --url <base> [--now <time>]
#
# <tree> and <previous> are the artifacts `signed-tree` and `served` of the run that did not finish. The credentials are
# those of sync-archive.sh and purge-cache.sh, in the environment; no signing key is needed.
#
# A publication that dies between two writes of the database group (a runner that is lost, a job that runs out of time)
# leaves a mixture of the two repositories, which no client can use and the next publication refuses to start from. Such a
# mixture, and only that, is put back to the previous repository. A group the dead run left as one of the two whole is not
# written over. Either way the edge is purged and what it serves is read the way the next publication reads it.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tree="" previous="" pub="" bucket="" url="" now=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::recover.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--tree) tree="$2" ;;
		--previous) previous="$2" ;;
		--public-key) pub="$2" ;;
		--bucket) bucket="$2" ;;
		--url) url="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::recover.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$tree" ] || [ -z "$previous" ] || [ -z "$pub" ] || [ -z "$bucket" ] || [ -z "$url" ]; then
	echo "::error::usage: recover.sh --tree <dir> --previous <dir> --public-key <file> --bucket <name> --url <base>" >&2
	exit 2
fi
bash "$HERE/scripts/publish/sync-archive.sh" --restore --if-mixed --tree "$tree" --previous "$previous" --public-key "$pub" --bucket "$bucket"
bash "$HERE/scripts/publish/purge-cache.sh" --url "$url" --tree "$tree"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
read_args=(--url "$url" --key "$pub")
[ -z "$now" ] || read_args+=(--now "$now")
# Nothing served at all is what a first publication that was put back leaves.
[ ! -e "$previous/no-state" ] || read_args+=(--first-publication)
attempts="${VERIFY_ATTEMPTS:-6}"
for attempt in $(seq 1 "$attempts"); do
	if bash "$HERE/scripts/metadata/read-served.sh" "${read_args[@]}" --out "$work/served$attempt"; then
		echo "recovered: the repository served at $url holds together"
		exit 0
	fi
	[ "$attempt" -ge "$attempts" ] || sleep "${VERIFY_DELAY:-10}"
done
echo "::error::the repository served at $url still does not hold together after the restore" >&2
exit 1
