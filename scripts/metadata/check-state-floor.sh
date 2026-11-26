#!/usr/bin/env bash
#
# Compare a state with the one recorded in the repository (state-floor.txt): the signature says who wrote a state, not
# that it is the newest, and whoever can write the bucket can serve an earlier one again.
#
#   check-state-floor.sh <state> <database> <floor file>
#
# Exit 0: the state is the recorded one or a newer one. Exit 4: nothing is recorded yet. Exit 1: the state is older than
# the recorded one, is another one under its sequence, or the record cannot be read. The state is judged as text here;
# its signature is the caller's to verify.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$#" -eq 3 ] || { echo "::error::usage: check-state-floor.sh <state> <database> <floor file>" >&2; exit 2; }
state="$1" db="$2" floor="$3"
if [ ! -f "$floor" ] || [ -L "$floor" ] || [ ! -r "$floor" ]; then
	echo "::error::$floor is not a readable regular file; without the record nothing says which state is old" >&2
	exit 1
fi
lines="$(grep -vE '^[[:space:]]*(#|$)' "$floor" || true)"
if [ "$lines" = none ]; then
	echo "no state is recorded in $floor yet"
	exit 4
fi
[[ "$lines" =~ ^([1-9][0-9]{0,11})\ ([0-9a-f]{64})$ ]] \
	|| { echo "::error::$floor does not hold exactly one line, 'none' or '<sequence> <sha256 of the database>'" >&2; exit 1; }
recorded="${BASH_REMATCH[1]}" digest="${BASH_REMATCH[2]}"
sequence="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$state" sequence)" \
	|| { echo "::error::cannot read the sequence of $state" >&2; exit 1; }
[[ "$sequence" =~ ^[1-9][0-9]{0,11}$ ]] || { echo "::error::the sequence of $state is not a number that can be compared" >&2; exit 1; }
if [ "$sequence" -lt "$recorded" ]; then
	echo "::error::the state has sequence $sequence and $floor records $recorded: an earlier signed repository was put back" >&2
	exit 1
fi
if [ "$sequence" -eq "$recorded" ] && [ "$(sha256sum "$db" | cut -d' ' -f1)" != "$digest" ]; then
	echo "::error::the state has the recorded sequence $recorded and its database is not the recorded one" >&2
	exit 1
fi
if [ "$sequence" -gt "$recorded" ]; then
	echo "::notice::the state has sequence $sequence, newer than the $recorded recorded in $floor; record it so that it cannot be taken back"
fi
