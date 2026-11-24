#!/usr/bin/env bash
#
# install-live.sh with stand-ins for pacman, curl and the installer: what it asks of pacman and in which order (the
# system upgrade first, the distribution's own package when asked, the installer of the repository, the check of the
# version, the second upgrade that must find nothing to do), and what it refuses: a version that is not the one expected,
# a keyring package that did not come, a second upgrade that still has something to do, a command that fails. The real
# thing, in a real Arch container against a real repository, is tests/rehearsal/rehearse.sh.
#
# Requires: coreutils.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/verify/install-live.sh"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/pacman" <<'TOOL'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$TOOL_LOG"
case "$1" in
	-Q)
		case "$2" in
			glyndor-keyring) [ "${FAKE_NO_KEYRING:-0}" = 1 ] && exit 1 || echo "glyndor-keyring 1.0.1700000000-1" ;;
			*) echo "$2 ${FAKE_VERSION:-1.0.0-1}" ;;
		esac
		;;
	-Syu) [ "${FAKE_BUSY:-0}" = 1 ] && echo ":: Starting full system upgrade..." || echo " there is nothing to do" ;;
esac
TOOL
cat > "$WORK/bin/pacman-key" <<'TOOL'
#!/usr/bin/env bash
printf 'pacman-key %s\n' "$*" >> "$TOOL_LOG"
TOOL
cat > "$WORK/bin/curl" <<'TOOL'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac; done
printf 'echo installer-ran >> "$TOOL_LOG"\n' > "$out"
TOOL
chmod +x "$WORK/bin/pacman" "$WORK/bin/curl" "$WORK/bin/pacman-key"
mkdir -p "$WORK/gnupg/private-keys-v1.d"
export PACMAN_GNUPG_DIR="$WORK/gnupg"
export PATH="$WORK/bin:$PATH" TOOL_LOG="$WORK/tools.log"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
run() { : > "$TOOL_LOG"; bash "$SCRIPT" "$@"; }

check "an install that finds what it expects" "0" "$(rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1)"
check "asks pacman for the system upgrade first, then the version, the keyring, and the second upgrade" "pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm
installer-ran
pacman -Q glyndor-keyring
pacman -Q podup
pacman -Syu --noconfirm" "$(cat "$TOOL_LOG")"
check "with the distribution's package, it is installed before the installer" "pacman-key --populate archlinux
pacman -Syu --noconfirm
pacman -S --noconfirm podman
installer-ran" "$(rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1 --distro podman > /dev/null; sed -n 2,5p "$TOOL_LOG")"
check "a version that is not the one expected" "1" "$(FAKE_VERSION=0.9.0-1 rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1)"
check "and says what pacman reports" "1" "$(says 'pacman reports podup 0.9.0-1, expected 1.0.0-1')"
check "a keyring package that did not come in" "1" "$(FAKE_NO_KEYRING=1 rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1)"
check "a second upgrade that still has something to do" "1" "$(FAKE_BUSY=1 rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1)"
check "a command to run that fails" "1" "$(rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1 --run false)"
check "a command to run that works" "0" "$(rc_of run install --base https://pacman.example.org --package podup --expect 1.0.0-1 --run true)"
check "the upgrade on the same host finds the newer version" "0" "$(FAKE_VERSION=1.1.0-1 rc_of run upgrade --package podup --expect 1.1.0-1)"
check "and does not run the installer again" "0" "$(grep -c installer-ran "$TOOL_LOG" || true)"
check "the upgrade that finds the old version" "1" "$(rc_of run upgrade --package podup --expect 1.1.0-1)"
check "no mode" "2" "$(rc_of run --package podup --expect 1.0.0-1)"
check "a version that is not X.Y.Z[+rN]-1" "2" "$(rc_of run install --base https://x.example.org --package podup --expect 1.0)"
check "a package name with a slash" "2" "$(rc_of run install --base https://x.example.org --package ../x --expect 1.0.0-1)"
check "an install with no base" "2" "$(rc_of run install --package podup --expect 1.0.0-1)"
check "a distribution package that is not a name" "2" "$(rc_of run install --base https://x.example.org --package podup --expect 1.0.0-1 --distro 'a b')"
check "an option that is not known" "2" "$(rc_of run install --nope x)"
check "a host that already has a keyring is not initialised again" "0" "$(touch "$WORK/gnupg/private-keys-v1.d/master.key"; run install --base https://pacman.example.org --package podup --expect 1.0.0-1 > /dev/null; grep -c pacman-key "$TOOL_LOG" || true)"

finish
