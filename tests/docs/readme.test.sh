#!/usr/bin/env bash
#
# The README gives the commands a reader pastes into a root shell and the fingerprint they compare a key with. Each of
# them is tied here to what the repository serves: the fingerprint to the key in keyring/, the repository block to the one
# the installer writes, the address of the installer and of the key to the ones the page builder and the installer use,
# the package names to the products file, and the command that installs to the one the installer runs. A README that
# said something else would be believed over the code.
#
# Requires: gpg.
# shellcheck disable=SC2016 # the patterns are text of the README and of the installer, with $ and backticks meant literally
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
README="$HERE/README.md"
TEMPLATE="$HERE/scripts/pages/install-template.sh"
home="$WORK/gnupg"
mkdir -m 700 "$home"
fpr="$(gpg --homedir "$home" --batch --with-colons --import-options show-only --import "$HERE/keyring/glyndor-pacman-key.asc" 2> /dev/null | awk -F: '$1 == "fpr" { print $10 }')"

check "the fingerprint written in groups is the one of the key in keyring/" "$fpr" "$(grep -E '^[0-9A-F]{4}( [0-9A-F]{4}){9}$' "$README" | tr -d ' ')"
check "the long fingerprint of the by-hand steps is that key's too" "1" "$(grep -c -- "--lsign-key $fpr" "$README")"
check "and the installer pins the same one" "1" "$(grep -c "^DEFAULT_FPR=\"$fpr\"" "$TEMPLATE")"
check "the block of the README is the one the installer writes (check, then server line)" "SigLevel = Required DatabaseRequired TrustedOnly
Server = https://pacman.glyndor.net/arch/x86_64" "$(sed -n '/^   \[glyndor\]/,/^   Server/p' "$README" | sed 's/^   //' | tail -2)"
check "the installer writes the same two lines" "2" "$(grep -c -F -e 'print "SigLevel = Required DatabaseRequired TrustedOnly"' -e 'print "Server = " ENVIRON["GLYNDOR_SERVER"]' "$TEMPLATE")"
check "the server address of the installer is the base and arch/x86_64" "1" "$(grep -c 'GLYNDOR_SERVER="$BASE/arch/x86_64"' "$TEMPLATE")"
check "the base of the installer is the host of the README" "1" "$(grep -c 'BASE="${GLYNDOR_PACMAN_BASE:-https://pacman.glyndor.net}"' "$TEMPLATE")"
check "the install line of the README is the one the installer runs, with -Syu" "1" "$(grep -c '^pacman -Syu --needed @PRODUCT@ glyndor-keyring$' "$TEMPLATE")"
check "the README writes pacman -Sy once, in the sentence that says it fails" "1" "$(grep -c 'pacman -Sy[^u]' "$README")"
check "it names pacman -Sy only to say that it fails" "1" "$(grep -c '`pacman -Sy podup` on its own would be a partial upgrade' "$README")"
check "the installer URL of the README is the path the installer is served under" "1" "$(grep -c '^curl -fsSL https://pacman.glyndor.net/install/podup | sudo sh$' "$README")"
check "and its product is a package of the products file" "1" "$(grep -c '^[a-z-]*	podup	' "$HERE/scripts/admit/products.txt")"
for package in podman podup epistle helmly-agent helmly epistle-panel; do
	check "the README names $package, which the products file declares" "2" "$(grep -c -e "	$package	" -e "\`$package\`" "$README" "$HERE/scripts/admit/products.txt" | awk -F: '{ s += ($2 > 0) } END { print s }')"
done
check "the key address of the README is the one the installer downloads" "1" "$(grep -c '"$BASE/glyndor-pacman-key.asc"' "$TEMPLATE")"
check "and the README downloads it from there" "1" "$(grep -c 'https://pacman.glyndor.net/glyndor-pacman-key.asc' "$README")"
check "the README says that the install upgrades the system" "1" "$(grep -c 'upgrades the whole system' "$README")"
check "it says that aarch64 is not built, and why" "1" "$(grep -c 'no official `aarch64` port' "$README")"
check "it says that no pacman client checks a post-quantum signature" "1" "$(grep -c 'No pacman client checks a post-quantum signature' "$README")"
check "it says why the block goes before [core], and the way out" "2" "$(grep -c -e 'first repository that has it' -e 'IgnorePkg' "$README")"
check "it has no personal path and no address of a machine" "0" "$(grep -c -e '/home/' -e '192\.168\.' "$README" || true)"

finish
