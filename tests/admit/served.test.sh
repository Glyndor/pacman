#!/usr/bin/env bash
#
# served.py: the list of what the repository serves is read like input from a hostile server, and the admitted
# packages are compared with it by the numbers of the version, never by text. The list must be exactly lines of
# name, pkgver, sha256 and file, each ended; a version older than the served one and the same version with other
# bytes are both refusals.
#
# Requires: python3.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SERVED="$HERE/scripts/admit/served.py"
Z="$(printf '%064d' 0)"
ONE="$(printf '%064d' 1)"
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
# candidate <pkgver> [sha]: a manifest with one admitted package acme
candidate() { printf 'r\tacme\t%s\tx86_64\tacme-%s-x86_64.pkg.tar.zst\t1\t%s\tno\n' "$1" "$1" "${2:-$Z}" > "$WORK/manifest.tsv"; }
# list <pkgver> [sha]: what is served, one package acme
list() { printf 'acme\t%s\t%s\tacme-%s-x86_64.pkg.tar.zst\n' "$1" "${2:-$Z}" "$1" > "$WORK/served.tsv"; }
run() { python3 -I "$SERVED" --served "$WORK/served.tsv" --manifest "$WORK/manifest.tsv" "$@"; }

echo "-- the comparison"
candidate 1.0.0-1; list 0.9.0-1
check "an older served version: the candidate is accepted" "0" "$(rc_of run)"
list 1.0.0-1
check "the same version and the same bytes" "0" "$(rc_of run)"
list 1.0.0-1 "$ONE"
check "the same version with other bytes is refused" "1" "$(rc_of run)"
check "and says that bytes that change need a new version" "1" "$(says 'need a new version')"
list 1.0.1-1
check "a newer served patch version is refused" "1" "$(rc_of run)"
check "and says that a version never goes backwards" "1" "$(says 'never goes backwards')"
list 1.1.0-1; check "a newer served minor version is refused" "1" "$(rc_of run)"
list 2.0.0-1; check "a newer served major version is refused" "1" "$(rc_of run)"
list 1.0.0+r1-1; check "a served revision of the same version is newer, and refused" "1" "$(rc_of run)"
candidate 1.0.0+r12-1; list 1.0.0+r2-1
check "+r12 is newer than +r2 by the numbers, not by text" "0" "$(rc_of run)"
candidate 1.0.0+r2-1; list 1.0.0+r12-1
check "and +r2 is older than +r12" "1" "$(rc_of run)"
candidate 1.10.0-1; list 1.9.0-1
check "1.10.0 is newer than 1.9.0" "0" "$(rc_of run)"
candidate 1.9.0-1; list 1.10.0-1
check "and 1.9.0 is older than 1.10.0" "1" "$(rc_of run)"
candidate 1.0.0-1; list 1.0.0+r1-1
check "a plain 1.0.0 is older than its +r1" "1" "$(rc_of run)"
candidate 1.0.0+r1-1; list 1.0.0-1
check "and +r1 is newer than the plain one" "0" "$(rc_of run)"
candidate 1.0.0-1; printf 'other\t9.9.9-1\t%s\tother-9.9.9-1-x86_64.pkg.tar.zst\n' "$Z" > "$WORK/served.tsv"
check "another package served, however new, does not matter" "0" "$(rc_of run)"

echo "-- a candidate that is not of the form the contract fixes"
list 1.0.0-1
printf 'r\tacme\t1.0-1\tx86_64\tacme-1.0-1-x86_64.pkg.tar.zst\t1\t%s\tno\n' "$Z" > "$WORK/manifest.tsv"
check "a version in the manifest that is not X.Y.Z[+rN]-1 is refused" "1" "$(rc_of run)"
check "and says the form" "1" "$(says 'is not of the form X.Y.Z')"

echo "-- the list is read strictly"
candidate 1.0.0-1
# shellcheck disable=SC2059 # the caller gives the format
raw() { printf "$@" > "$WORK/served.tsv"; }
good="acme\t0.9.0-1\t$Z\tacme-0.9.0-1-x86_64.pkg.tar.zst"
raw "$good\n"; check "a list of one good line" "0" "$(rc_of run)"
raw "$good"; check "a list whose last line is not ended" "1" "$(rc_of run)"
check "and says that it does not end with a line feed" "1" "$(says 'does not end with a line feed')"
raw "$good\n\n"; check "a blank line" "1" "$(rc_of run)"
raw "acme\t0.9.0-1\t$Z\n"; check "three fields" "1" "$(rc_of run)"
raw "$good\textra\n"; check "five fields" "1" "$(rc_of run)"
raw "acme\t0.9.0-1\t%s\tacme-0.9.0-1-x86_64.pkg.tar.zst\n" "$(printf 'G%.0s' $(seq 1 64))"; check "a sha256 that is not hexadecimal" "1" "$(rc_of run)"
raw "acme\t0.9.0-1\t%s\tacme-0.9.0-1-x86_64.pkg.tar.zst\n" "$(printf 'A%.0s' $(seq 1 64))"; check "a sha256 in upper case" "1" "$(rc_of run)"
raw "acme\t0.9-1\t$Z\tacme-0.9-1-x86_64.pkg.tar.zst\n"; check "a version that is not X.Y.Z" "1" "$(rc_of run)"
raw "acme\t0.9.0-2\t$Z\tacme-0.9.0-2-x86_64.pkg.tar.zst\n"; check "a revision other than -1" "1" "$(rc_of run)"
raw "acme\t0.9.0-1\t$Z\tother-0.9.0-1-x86_64.pkg.tar.zst\n"; check "a file that is not the package's" "1" "$(rc_of run)"
raw "acme\t0.9.0-1\t$Z\tacme-0.9.0-1-x86_64.pkg.tar.xz\n"; check "a file that is not a .pkg.tar.zst" "1" "$(rc_of run)"
raw "$good\r\n"; check "a carriage return" "1" "$(rc_of run)"
raw "$good\n$good\n"; check "a package listed twice" "1" "$(rc_of run)"
raw "ACME\t0.9.0-1\t$Z\tACME-0.9.0-1-x86_64.pkg.tar.zst\n"; check "a name in upper case" "1" "$(rc_of run)"
raw "acme 0.9.0-1 $Z acme-0.9.0-1-x86_64.pkg.tar.zst\n"; check "spaces in place of tabs" "1" "$(rc_of run)"
: > "$WORK/served.tsv"
check "an empty list is refused" "1" "$(rc_of run)"
check "and says that it is not the first publication" "1" "$(says 'not the first publication')"
check "and that is all it says (it stopped there)" "0" "$(says 'line feed')"
check "an empty list is read when the run is the first publication" "0" "$(rc_of run --allow-empty)"
raw '\n'; check "a list of only a line feed is not empty" "1" "$(rc_of run --allow-empty)"
check "a list that is not there" "1" "$(rm -f "$WORK/served.tsv"; rc_of run)"
check "a manifest that is not there" "1" "$(raw "$good\n"; rc_of python3 -I "$SERVED" --served "$WORK/served.tsv" --manifest "$WORK/none")"

finish
