#!/usr/bin/env bash
#
# Put back the repository a publication left half written, from what that run kept, and read it back.
#
#   recover.sh --tree <dir> --previous <dir> --public-key <file> --bucket <name> --url <base> [--floor <file>]
#              [--expired-state "<sequence> <sha256>"] [--now <time>]
#
# <tree> and <previous> are the artifacts `signed-tree` and `served` of the run that did not finish. The credentials are
# those of sync-archive.sh and purge-cache.sh, in the environment; no signing key is needed.
#
# A publication that dies between two writes of the database group (a runner that is lost, a job that runs out of time)
# leaves a mixture of the two repositories, which no client can use and the next publication refuses to start from. Such a
# mixture, and only that, is put back to the previous repository. A group the dead run left as one of the two whole is not
# written over. Either way the edge is purged and what it serves is read the way the next publication reads it. The
# previous repository is what the dead run read from the bucket, so it is compared with the recorded state
# (state-floor.txt) before anything is written: a recovery does not put back an earlier one.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tree="" previous="" pub="" bucket="" url="" now="" expected=""
floor="$HERE/scripts/metadata/state-floor.txt"
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::recover.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--tree) tree="$2" ;;
		--previous) previous="$2" ;;
		--public-key) pub="$2" ;;
		--bucket) bucket="$2" ;;
		--url) url="$2" ;;
		--floor) floor="$2" ;;
		--expired-state) expected="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::recover.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$tree" ] || [ -z "$previous" ] || [ -z "$pub" ] || [ -z "$bucket" ] || [ -z "$url" ]; then
	echo "::error::usage: recover.sh --tree <dir> --previous <dir> --public-key <file> --bucket <name> --url <base>" >&2
	exit 2
fi
if [ -n "$expected" ] && ! [[ "$expected" =~ ^[1-9][0-9]{0,11}\ [0-9a-f]{64}$ ]]; then
	echo "::error::--expired-state takes '<sequence> <sha256 of the database>'" >&2
	exit 2
fi
if [ -e "$previous/no-state" ]; then
	# Removing what a first publication wrote is only right while nothing is recorded as served.
	[ -f "$floor" ] && [ "$(grep -vE '^[[:space:]]*(#|$)' "$floor")" = none ] \
		|| { echo "::error::the run to recover from was a first publication and $floor does not say that nothing was published; nothing is written" >&2; exit 1; }
	expired=""
else
	rc=0
	bash "$HERE/scripts/metadata/check-state-floor.sh" "$previous/state" "$previous/glyndor.db.tar.zst" "$floor" || rc=$?
	[ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || { echo "::error::the previous repository of that run is not one to put back; nothing is written" >&2; exit 1; }
	until="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$previous/state" valid-until)" \
		|| { echo "::error::cannot read the previous state; nothing is written" >&2; exit 1; }
	expired=""
	# Both are YYYY-MM-DDTHH:MM:SSZ, which sorts as text in the order of time.
	if ! [[ "$until" > "${now:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" ]]; then
		expired="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$previous/state" sequence) $(sha256sum "$previous/glyndor.db.tar.zst" | cut -d' ' -f1)"
		recorded="$(grep -vE '^[[:space:]]*(#|$)' "$floor")"
		[ "$expired" = "$recorded" ] || [ "$expired" = "$expected" ] \
			|| { echo "::error::the previous state '$expired' expired at $until and is neither the recorded one nor the one named with expired_state; nothing is written" >&2; exit 1; }
	fi
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bash "$HERE/scripts/publish/sync-archive.sh" --restore --if-mixed --tree "$tree" --previous "$previous" --public-key "$pub" --bucket "$bucket" \
	| tee "$work/restore.log"
bash "$HERE/scripts/publish/purge-cache.sh" --url "$url" --tree "$tree"

read_args=(--url "$url" --key "$pub" --floor "$floor")
# An expired previous state is what is served now, unless the dead run had written the whole of the new one.
if [ -n "$expired" ] && ! grep -qx 'held=new' "$work/restore.log"; then
	read_args+=(--expired-state "$expired")
fi
[ -z "$now" ] || read_args+=(--now "$now")
# Nothing served at all is what a first publication that was put back leaves.
[ ! -e "$previous/no-state" ] || read_args+=(--first-publication)
attempts="${VERIFY_ATTEMPTS:-6}"
for attempt in $(seq 1 "$attempts"); do
	if bash "$HERE/scripts/metadata/read-served.sh" "${read_args[@]}" --out "$work/served$attempt"; then
		echo "recovered: the repository served at $url holds together"
		until_left="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$work/served$attempt/state" valid-until)" || until_left=""
		if [ -n "$until_left" ] && ! [[ "$until_left" > "${now:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" ]]; then
			echo "::warning::the repository served at $url holds a state that expired at $until_left"
			echo "the state published: $(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$work/served$attempt/state" sequence) $(sha256sum "$work/served$attempt/glyndor.db.tar.zst" | cut -d' ' -f1)"
			echo "the next publication needs that state as expired_state, or nothing can be published over it"
		fi
		exit 0
	fi
	[ "$attempt" -ge "$attempts" ] || sleep "${VERIFY_DELAY:-10}"
done
echo "::error::the repository served at $url still does not hold together after the restore" >&2
exit 1
