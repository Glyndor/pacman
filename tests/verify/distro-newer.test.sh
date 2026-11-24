#!/usr/bin/env bash
#
# distro-newer.sh with stand-ins for pacman and vercmp: it fails when Arch carries a newer version of a package the
# repository serves, and not when Arch is older, equal, or has no such package. The comparison itself is the vercmp of
# pacman, which build-database.test.sh runs for real; here the stand-in only orders plain numbers.
#
# Requires: coreutils.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/verify/distro-newer.sh"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/pacman" <<'TOOL'
#!/usr/bin/env bash
case "$1" in
	-Sy) exit 0 ;;
	-Si)
		shift
		[ "${1:-}" != -- ] || shift
		if [ -n "${FAKE_PACMAN_ERROR:-}" ]; then echo "$FAKE_PACMAN_ERROR" >&2; exit 1; fi
		if ! grep -q -E "^$1	" "$DISTRO"; then echo "error: package '$1' was not found" >&2; exit 1; fi
		if [ "${FAKE_NO_VERSION:-0}" = 1 ]; then echo "Name           : $1"; exit 0; fi
		grep -E "^$1	" "$DISTRO" | awk -F'\t' '{ print "Name           : " $1; print "Version        : " $2; print "Description    : a: b: c" }'
		;;
esac
TOOL
cat > "$WORK/bin/vercmp" <<'TOOL'
#!/usr/bin/env bash
# a stand-in that knows the epoch: the number before a colon decides first, then the rest by version order
epoch() { case "$1" in *:*) echo "${1%%:*}" ;; *) echo 0 ;; esac; }
rest() { echo "${1#*:}"; }
ea="$(epoch "$1")"; eb="$(epoch "$2")"
if [ "$ea" -gt "$eb" ]; then echo 1; exit 0; fi
if [ "$ea" -lt "$eb" ]; then echo -1; exit 0; fi
a="$(rest "$1")"; b="$(rest "$2")"
if [ "$a" = "$b" ]; then echo 0; elif [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$a" ]; then echo -1; else echo 1; fi
TOOL
chmod +x "$WORK/bin/pacman" "$WORK/bin/vercmp"
export PATH="$WORK/bin:$PATH" DISTRO="$WORK/distro.tsv"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
Z="$(printf '%064d' 0)"
printf 'podman\t6.2.0-1\t%s\tpodman-6.2.0-1-x86_64.pkg.tar.zst\npodup\t5.0.0-1\t%s\tpodup-5.0.0-1-x86_64.pkg.tar.zst\n' "$Z" "$Z" > "$WORK/served.tsv"

printf 'podman\t6.1.0-1\n' > "$DISTRO"
check "Arch carries an older podman: nothing to say" "0" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
printf 'podman\t6.2.0-1\n' > "$DISTRO"
check "the same version" "0" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
printf 'other\t1-1\n' > "$DISTRO"
check "a package Arch does not carry is skipped" "0" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
printf 'podman\t6.9.0-1\n' > "$DISTRO"
check "Arch carries a newer podman" "1" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
check "and the message names the package and both versions" "1" "$(says 'Arch has podman 6.9.0-1 and this repository serves 6.2.0-1')"
printf 'podman\t6.1.0-1\npodup\t5.0.1-1\n' > "$DISTRO"
check "one newer package among several fails the run" "1" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
printf 'podman\t6.2.0-1\n' > "$DISTRO"
check "a served name that is not a package name is refused" "1" "$(printf 'bad name\t1.0.0-1\t%s\tx\n' "$Z" > "$WORK/bad.tsv"; rc_of bash "$SCRIPT" --served "$WORK/bad.tsv")"
check "a served list that is not there" "2" "$(rc_of bash "$SCRIPT" --served "$WORK/none.tsv")"
check "an option that is not known" "2" "$(rc_of bash "$SCRIPT" --nope x)"
check "no option" "2" "$(rc_of bash "$SCRIPT")"

echo "-- an epoch is part of the version, and what is not an explicit absence is a failure"
printf 'podman\t1:2.3-1\n' > "$DISTRO"
check "Arch carries 1:2.3-1 and the repository serves 6.2.0-1: Arch is newer, by the epoch" "1" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
check "and the message says the whole version, epoch included" "1" "$(says 'Arch has podman 1:2.3-1')"
printf 'podman\t0:6.2.0-1\n' > "$DISTRO"
check "an explicit epoch of 0 does not make 6.2.0-1 older" "0" "$(rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
printf 'podman\t6.1.0-1\n' > "$DISTRO"
check "a failure that is not 'was not found' stops the run" "1" "$(FAKE_PACMAN_ERROR="error: failed to prepare transaction (could not satisfy dependencies)" rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
check "and says that it cannot read the package" "1" "$(says 'cannot read podman')"
check "a 'was not found' about another package is not the absence of this one" "1" "$(FAKE_PACMAN_ERROR="error: package 'other' was not found" rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
check "an answer with no Version line is a failure, not an absence" "1" "$(FAKE_NO_VERSION=1 rc_of bash "$SCRIPT" --served "$WORK/served.tsv")"
finish
