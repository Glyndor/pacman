#!/bin/sh
# Set up the Glyndor pacman repository and install @PRODUCT@.
#
# Usage: curl -fsSL https://pacman.glyndor.net/install/@PRODUCT@ | sudo sh
#
# Generated from scripts/pages/install-template.sh in Glyndor/pacman. Do not edit the published copy.
#
# This script is served from the same storage as the packages, so it cannot vouch for itself: what it checks
# is the fingerprint of the repository key against a constant written below and published in the README, and
# the README gives the same steps one by one for a reader who wants to run them by hand. pacman verifies the
# signature of every database and every package against that key before it opens one.
#
# It runs `pacman -Syu --needed @PRODUCT@ glyndor-keyring`, which UPGRADES THE SYSTEM, and brings the keyring package with every product so that a rotation of the key reaches the host. The repository replaces netavark,
# and aardvark-dns with its own Podman, and depends on the containers-common of Arch, and pacman applies a replacement only in a system
# upgrade; `pacman -Sy @PRODUCT@` would be a partial upgrade and fails on a host that has the distribution's Podman.
#
# Everything executable is inside the function, and its invocation is the last line: a shell reading a truncated
# pipe must finish parsing the definition before it can run it.
install_main() {
set -eu

BASE="${GLYNDOR_PACMAN_BASE:-https://pacman.glyndor.net}"
DEFAULT_FPR="0EE5C891235BE1CAD2E0ABA477E416B24362E256"
# For a repository of another key (a fork, a rehearsal). It is said aloud, like the base: this constant is what protects the install.
FPR="${GLYNDOR_PACMAN_FPR:-$DEFAULT_FPR}"
CONF="${PACMAN_CONF:-/etc/pacman.conf}"

die() {
	printf 'glyndor: %s\n' "$1" >&2
	exit 1
}

# A base other than the real one is said aloud: the fingerprint below is what still protects the install, and
# a copied command line that points elsewhere is the one case a reader would not otherwise see.
if [ "$BASE" != "https://pacman.glyndor.net" ]; then
	printf 'glyndor: using %s instead of https://pacman.glyndor.net\n' "$BASE" >&2
fi
if [ "$FPR" != "$DEFAULT_FPR" ]; then
	printf 'glyndor: trusting the key %s instead of %s\n' "$FPR" "$DEFAULT_FPR" >&2
fi
case "$FPR" in
	*[!0-9A-F]* | '') die "the fingerprint is upper-case hexadecimal digits" ;;
esac
[ "${#FPR}" -eq 40 ] || die "the fingerprint is 40 digits"
# The whole string is judged, not its start: it ends up in a file that pacman reads, and in a program of awk. Only a host
# of letters, digits, dots and hyphens (https), or the loopback with a numeric port (http, for a rehearsal), no path, no
# backslash, no space, no control character, none of @ ? # that would turn the host into something else.
if ! printf '%s' "$BASE" | grep -Eq '^(https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|http://(127\.0\.0\.1|localhost):[0-9]{1,5})$'; then
	die "the base address is not an https host, or the loopback with a port"
fi

[ "$(id -u)" -eq 0 ] || die "run it as root, for example: curl -fsSL $BASE/install/@PRODUCT@ | sudo sh"
fetcher=curl
for tool in pacman pacman-key gpg "$fetcher" awk grep; do
	command -v "$tool" > /dev/null 2>&1 || die "$tool is not installed; this is for Arch Linux and what derives from it"
done
[ "$(uname -m)" = x86_64 ] || die "the repository carries x86_64 packages only; Arch Linux has no official aarch64 port"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM

curl --silent --show-error --fail --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 60 \
	--max-filesize 65536 --output "$work/key.asc" "$BASE/glyndor-pacman-key.asc" || die "cannot download the repository key"
mkdir -m 700 "$work/gnupg"
fingerprints="$(gpg --homedir "$work/gnupg" --batch --with-colons --import-options show-only --import "$work/key.asc" 2> /dev/null \
	| awk -F: '$1 == "fpr" { print $10 }')" || die "the downloaded file is not an OpenPGP key"
[ "$fingerprints" = "$FPR" ] || die "the key served does not have the fingerprint $FPR; nothing was changed"

# The repository goes BEFORE [core]: pacman takes a package from the first repository that has it, and the
# Podman of this one must win over the one of [extra]. IgnorePkg in pacman.conf is the way to opt a package out.
if grep -q '^\[glyndor\]' "$CONF"; then
	printf 'glyndor: [glyndor] is already in %s; leaving it as it is\n' "$CONF"
else
	grep -q '^\[core\]' "$CONF" || die "$CONF has no [core] section to put the repository before; add the block of the README by hand"
	GLYNDOR_SERVER="$BASE/arch/x86_64" awk '
		!done && /^\[core\]/ {
			print "[glyndor]"
			print "SigLevel = Required DatabaseRequired TrustedOnly"
			print "Server = " ENVIRON["GLYNDOR_SERVER"]
			print ""
			done = 1
		}
		{ print }
	' "$CONF" > "$work/pacman.conf" || die "cannot write the new $CONF"
	cp -- "$CONF" "$CONF.glyndor-backup"
	cat -- "$work/pacman.conf" > "$CONF"
	printf 'glyndor: added [glyndor] to %s (a copy of the old file is %s.glyndor-backup)\n' "$CONF" "$CONF"
fi

pacman-key --add "$work/key.asc" > /dev/null
pacman-key --lsign-key "$FPR" > /dev/null
pacman -Syu --needed @PRODUCT@ glyndor-keyring
}
{ install_main; }
