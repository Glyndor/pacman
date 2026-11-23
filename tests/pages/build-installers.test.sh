#!/usr/bin/env bash
#
# build-installers.sh: one installer per package from one template. A template that lost its placeholder, a name
# that is not a package name (it would reach a shell as an option or a path), an installer that is not valid shell or
# does not end by its function call (a script cut by a dropped connection must not run) all stop the build.
#
# Requires: coreutils, sh.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/pages/build-installers.sh"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }

check "two installers are generated" "0" "$(rc_of bash "$SCRIPT" "$WORK/out" podup epistle)"
check "one file per package, executable" "epistle podup" "$(cd "$WORK/out" && find . -type f -perm -755 -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "the name is in the script and the placeholder is gone" "0" "$(grep -c '@PRODUCT@' "$WORK/out/podup" || true)"
check "the install line carries the name and the system upgrade" "1" "$(grep -c '^pacman -Syu --needed podup glyndor-keyring$' "$WORK/out/podup")"
check "each installer ends with the call of its function" "{ install_main; }" "$(tail -n 1 "$WORK/out/epistle")"
check "an installer is valid shell" "0" "$(sh -n "$WORK/out/podup"; echo $?)"
check "a package name with a slash is refused" "1" "$(rc_of bash "$SCRIPT" "$WORK/o2" ../x)"
check "a name that starts with a dash is refused" "1" "$(rc_of bash "$SCRIPT" "$WORK/o3" -rf)"
check "an upper-case name is refused" "1" "$(rc_of bash "$SCRIPT" "$WORK/o4" Podup)"
check "a name with a space is refused" "1" "$(rc_of bash "$SCRIPT" "$WORK/o5" 'a b')"
check "a name with a semicolon is refused" "1" "$(rc_of bash "$SCRIPT" "$WORK/o6" 'a;rm')"
check "and says it is not a package name" "1" "$(says 'not a pacman package name')"
check "an installer that already exists is not overwritten" "1" "$(rc_of bash "$SCRIPT" "$WORK/out" podup)"
check "no package at all is a usage error" "2" "$(rc_of bash "$SCRIPT" "$WORK/o7")"

finish
