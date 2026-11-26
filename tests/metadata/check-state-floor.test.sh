#!/usr/bin/env bash
#
# check-state-floor.sh: a state is compared with the one the repository records, and anything that leaves the comparison
# unmade is a refusal. read-served.test.sh runs it behind the reading of a served repository.
#
# Requires: python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/metadata/check-state-floor.sh"
printf 'a database' > "$WORK/db"
DIGEST="$(sha256sum "$WORK/db" | cut -d' ' -f1)"
state() { # <sequence>: a state file with that sequence
	printf '%s\n' "glyndor-pacman-state: 1" "repository: glyndor" "architecture: x86_64" "sequence: $1" "generated: 2026-11-23T06:00:00Z" \
		"valid-until: 2026-12-07T06:00:00Z" "db-sha256: $DIGEST" "packages: 1" > "$WORK/state"
}
record() { printf '# a comment\n\n%s\n' "$1" > "$WORK/floor"; }
rc_of() { local rc=0; bash "$SCRIPT" "$WORK/state" "$WORK/db" "$WORK/floor" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }

state 7
record none
check "nothing recorded yet is its own answer" "4" "$(rc_of)"
record "7 $DIGEST"
check "the recorded state" "0 0" "$(rc_of) $(says '::')"
record "6 $(printf '%064d' 0)"
check "a newer one, with a notice to record it" "0 1" "$(rc_of) $(says '::notice::the state has sequence 7, newer than the 6 recorded')"
record "8 $DIGEST"
check "an earlier one" "1 1" "$(rc_of) $(says 'an earlier signed repository was put back')"
record "10 $DIGEST"
check "sequences are compared as numbers, not as text" "1" "$(rc_of)"
record "7 $(printf '%064d' 0)"
check "the recorded sequence with another database" "1 1" "$(rc_of) $(says 'is not the recorded one')"
for bad in "" "7" "7 ${DIGEST:1}" "seven $DIGEST" "0 $DIGEST" "1234567890123 $DIGEST" "7 $DIGEST extra" "$(printf 'none\n7 %s' "$DIGEST")" "$(printf '7 %s\n8 %s' "$DIGEST" "$DIGEST")"; do
	record "$bad"
	check "the record '${bad:0:16}' is refused" "1 1" "$(rc_of) $(says 'does not hold exactly one line')"
done
rm "$WORK/floor"
check "a record that is not there" "1 1" "$(rc_of) $(says 'is not a readable regular file')"
record "7 $DIGEST"; mv "$WORK/floor" "$WORK/real"; ln -s "$WORK/real" "$WORK/floor"
check "a record that is a link" "1 1" "$(rc_of) $(says 'is not a readable regular file')"
rm "$WORK/floor"; record "7 $DIGEST"
printf 'junk\n' > "$WORK/state"
check "a state that cannot be read" "1 1" "$(rc_of) $(says 'cannot read the sequence')"
state 12345678901234567890
check "a sequence too long to compare" "1 1" "$(rc_of) $(says 'is not a number that can be compared')"
check "the wrong number of arguments" "2" "$(rc=0; bash "$SCRIPT" a b > /dev/null 2>&1 || rc=$?; echo "$rc")"
check "the record the repository ships says that nothing is published, or holds one line a read can use" "yes" \
	"$(l="$(grep -vE '^[[:space:]]*(#|$)' "$HERE/scripts/metadata/state-floor.txt")"; [[ "$l" = none || "$l" =~ ^[1-9][0-9]{0,11}\ [0-9a-f]{64}$ ]] && echo yes || echo no)"

finish
