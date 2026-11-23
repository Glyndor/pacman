#!/usr/bin/env bash
#
# The installer a user pipes into a root shell, run against a pacman.conf of a temp folder and a pacman that
# writes down what it was asked. What it must do is narrow: take the key from the repository, compare its
# fingerprint with the constant it carries and stop on any other, put the [glyndor] block before [core],
# trust the key locally, and run `pacman -Syu --needed <package> glyndor-keyring`, never `-Sy`. A script cut short by a dropped
# connection must do nothing at all.
#
# Requires: gpg, python3, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
mkdir -p "$WORK/out"
bash "$HERE/scripts/pages/build-installers.sh" "$WORK/out" acme > /dev/null
INSTALLER="$WORK/out/acme"
make_gpg_key "$WORK/other"
mkdir -p "$WORK/site"
cp "$HERE/keyring/glyndor-pacman-key.asc" "$WORK/site/glyndor-pacman-key.asc"
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
( cd "$WORK/site" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 > "$WORK/server.log" 2>&1 ) &
SERVER=$!
trap 'kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
until curl --silent --max-time 2 "http://127.0.0.1:$PORT/" > /dev/null 2>&1; do sleep 0.2; done
export GLYNDOR_PACMAN_BASE="http://127.0.0.1:$PORT"
mkdir -p "$WORK/bin"
for tool in pacman pacman-key; do
	cat > "$WORK/bin/$tool" <<'TOOL'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$TOOL_LOG"
TOOL
	chmod +x "$WORK/bin/$tool"
done
# shellcheck disable=SC2016 # the stand-ins read their own environment
printf '#!/bin/sh\necho "${FAKE_UID:-0}"\n' > "$WORK/bin/id"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "${FAKE_ARCH:-x86_64}"\n' > "$WORK/bin/uname"
chmod +x "$WORK/bin/id" "$WORK/bin/uname"
export TOOL_LOG="$WORK/tools.log"
mkdir -p "$WORK/t"
export TMPDIR="$WORK/t"
export PATH="$WORK/bin:$PATH"
CONF_TEMPLATE="$WORK/pacman.conf.template"
printf '[options]\nHoldPkg = pacman glibc\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n' > "$CONF_TEMPLATE"
run() { # [env assignments are inherited]: runs the installer on a fresh conf
	cp "$CONF_TEMPLATE" "$WORK/pacman.conf"
	rm -f "$WORK/pacman.conf.glyndor-backup"
	: > "$TOOL_LOG"
	PACMAN_CONF="$WORK/pacman.conf" sh "${SCRIPT:-$INSTALLER}"
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }

check "the installer runs to its end with the key of the repository" "0" "$(rc_of run)"
check "the block is put before [core]" "[options]
HoldPkg = pacman glibc

[glyndor]
SigLevel = Required DatabaseRequired TrustedOnly
Server = http://127.0.0.1:$PORT/arch/x86_64

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist" "$(cat "$WORK/pacman.conf")"
check "the old file is kept beside it" "$(cat "$CONF_TEMPLATE")" "$(cat "$WORK/pacman.conf.glyndor-backup")"
check "the key is added, then trusted locally by its fingerprint, then the package is installed with a system upgrade" \
	"pacman-key --add KEY
pacman-key --lsign-key 0EE5C891235BE1CAD2E0ABA477E416B24362E256
pacman -Syu --needed acme glyndor-keyring" "$(sed -E 's|^(pacman-key --add ).*|\1KEY|' "$TOOL_LOG")"
check "it never runs -Sy, which is a partial upgrade" "0" "$(grep -c -e ' -Sy ' -e ' -Sy$' "$TOOL_LOG" || true)"
check "it says that a base other than the real one is in use" "1" "$(says 'using http://127.0.0.1')"
check "the temporary folder is gone" "0" "$(find "$WORK/t" -mindepth 1 | wc -l)"

echo "-- what it refuses, and leaves alone"
cp "$WORK/other/pub.asc" "$WORK/site/glyndor-pacman-key.asc"
check "a key with another fingerprint" "1" "$(rc_of run)"
check "says so, and that nothing was changed" "1" "$(says 'nothing was changed')"
check "and neither the file nor the keyring was touched" "$(cat "$CONF_TEMPLATE")" "$(cat "$WORK/pacman.conf")"
check "no pacman command ran" "0" "$(wc -l < "$TOOL_LOG" | tr -d ' ')"
cat "$HERE/keyring/glyndor-pacman-key.asc" "$WORK/other/pub.asc" > "$WORK/site/glyndor-pacman-key.asc"
check "the right key with another key beside it" "1" "$(rc_of run)"
printf 'not a key at all\n' > "$WORK/site/glyndor-pacman-key.asc"
check "a file that is not a key" "1" "$(rc_of run)"
rm "$WORK/site/glyndor-pacman-key.asc"
check "a key that is not served" "1" "$(rc_of run)"
cp "$HERE/keyring/glyndor-pacman-key.asc" "$WORK/site/glyndor-pacman-key.asc"
check "not root" "1" "$(FAKE_UID=1000 rc_of run)"
check "says to run it as root" "1" "$(says 'run it as root')"
check "another architecture" "1" "$(FAKE_ARCH=aarch64 rc_of run)"
check "says that Arch has no official aarch64 port" "1" "$(says 'no official aarch64 port')"
mkdir -p "$WORK/onlybin"
for tool in sh cat cp rm mktemp dirname; do ln -sf "$(command -v "$tool")" "$WORK/onlybin/$tool"; done
check "a tool that is missing (curl, gpg, pacman...)" "1" "$(PATH="$WORK/onlybin" rc_of run)"
check "a base that is plain http and not the loopback" "1" "$(GLYNDOR_PACMAN_BASE=http://example.org rc_of run)"
for bad in 'https://pacman.example.org/x' 'https://a b' 'https://pacman.example.org\\n[core]' 'https://user@pacman.example.org' 'https://pacman.example.org?x' 'https://pacman.example.org#x' \
	'http://127.0.0.1' 'http://127.0.0.1:80/x' 'http://127.0.0.1:port' 'https://' 'https://-' 'https://pacman.example.org:443'; do
	check "a base address of the form '$bad' is refused before anything is written" "1" "$(GLYNDOR_PACMAN_BASE="$bad" rc_of run)"
done
check "and the refusal says what a base is" "1" "$(says 'not an https host')"
check "a base with a line feed in it is refused" "1" "$(GLYNDOR_PACMAN_BASE="$(printf 'https://pacman.example.org\n[core]')" rc_of run)"
check "a base that is not a URL" "1" "$(GLYNDOR_PACMAN_BASE=ftp://example.org rc_of run)"
printf '[options]\n[extra]\n' > "$CONF_TEMPLATE"
check "a pacman.conf with no [core] to go before" "1" "$(rc_of run)"
check "and says to add the block by hand" "1" "$(says 'by hand')"
printf '[options]\n\n[glyndor]\nServer = https://elsewhere.invalid\n\n[core]\n' > "$CONF_TEMPLATE"
check "a pacman.conf that already has [glyndor]" "0" "$(rc_of run)"
check "is left as it is" "$(cat "$CONF_TEMPLATE")" "$(cat "$WORK/pacman.conf")"
check "and the package is still installed" "1" "$(grep -c "pacman -Syu --needed acme glyndor-keyring" "$TOOL_LOG" || true)"

echo "-- the fingerprint can be another one, and says so"
{ cat "$WORK/other/pub.asc"; } > "$WORK/site/glyndor-pacman-key.asc"
ofpr="$(cat "$WORK/other/fpr")"
check "a key that is not the pinned one is trusted when its fingerprint is given" "0" "$(GLYNDOR_PACMAN_FPR="$ofpr" rc_of run)"
check "and the installer says that it trusts another key" "1" "$(says 'trusting the key')"
check "that key is the one that is trusted locally" "1" "$(grep -c "pacman-key --lsign-key $ofpr" "$TOOL_LOG" || true)"
check "the pinned key is refused when another fingerprint is asked for" "1" "$(cp "$HERE/keyring/glyndor-pacman-key.asc" "$WORK/site/glyndor-pacman-key.asc"; GLYNDOR_PACMAN_FPR="$ofpr" rc_of run)"
check "a fingerprint in lower case is refused" "1" "$(GLYNDOR_PACMAN_FPR="$(printf '%s' "$ofpr" | tr 'A-F' 'a-f')" rc_of run)"
check "a fingerprint of 39 digits is refused" "1" "$(GLYNDOR_PACMAN_FPR="${ofpr#?}" rc_of run)"
cp "$HERE/keyring/glyndor-pacman-key.asc" "$WORK/site/glyndor-pacman-key.asc"

echo "-- a script cut short does nothing"
printf '[options]\n[core]\n' > "$CONF_TEMPLATE"
head -n -1 "$INSTALLER" > "$WORK/cut.sh"
SCRIPT="$WORK/cut.sh" run
check "the installer without its last line runs nothing" "0" "$(wc -l < "$TOOL_LOG" | tr -d ' ')"
check "and does not touch the file" "$(cat "$CONF_TEMPLATE")" "$(cat "$WORK/pacman.conf")"
head -c 3000 "$INSTALLER" > "$WORK/cut.sh"
check "the installer cut in the middle fails to parse and runs nothing" "0" "$(SCRIPT="$WORK/cut.sh" rc_of run > /dev/null; wc -l < "$TOOL_LOG" | tr -d ' ')"

finish
