#!/usr/bin/env bash
#
# Build the package that carries the key of the repository, byte for byte the same every time it is built from the same
# inputs. Runs INSIDE the pinned Arch image (run-in-arch.sh), as root, with no network and no secret.
#
#   build-keyring.sh --key <asc> --epoch <seconds> --out <dir>
#
# The package is `glyndor-keyring`, architecture `any`, and installs the key where `pacman-key --populate glyndor` reads
# it, so that a rotation of the key reaches a host with `pacman -Syu` like any other package. It is made without makepkg,
# which wants fakeroot and a build user: a fixed list of files, a fixed time on every entry (--epoch), sorted names,
# numeric owner 0 and nothing that depends on the machine, so that two builds give the same bytes. The same bytes matter:
# a published name never changes its hash (a build with another hash under the same version would be refused), and the
# version comes from the inputs, `1.0.<epoch>`, so that a new key or a new script is a new, higher version.
# It writes the package and nothing else.
set -euo pipefail
export LC_ALL=C

key="" epoch="" out=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::build-keyring.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--key) key="$2" ;;
		--epoch) epoch="$2" ;;
		--out) out="$2" ;;
		*) echo "::error::build-keyring.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$key" ] || [ -z "$epoch" ] || [ -z "$out" ]; then
	echo "::error::usage: build-keyring.sh --key <asc> --epoch <seconds> --out <dir>" >&2
	exit 2
fi
[[ "$epoch" =~ ^[1-9][0-9]{8,10}$ ]] || { echo "::error::the epoch is a number of seconds" >&2; exit 2; }
[ -f "$key" ] || { echo "::error::$key is not a file" >&2; exit 2; }
[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 2; }
export SOURCE_DATE_EPOCH="$epoch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
home="$work/gnupg"
mkdir -m 700 "$home"
fingerprints="$(gpg --homedir "$home" --batch --with-colons --import-options show-only --import "$key" 2> /dev/null | awk -F: '$1 == "fpr" { print $10 }')" || fingerprints=''
[[ "$fingerprints" =~ ^[0-9A-F]{40}$ ]] || { echo "::error::$key does not hold exactly one key" >&2; exit 1; }

pkgver="1.0.$epoch"
root="$work/root"
install -d -m 755 "$root/usr/share/pacman/keyrings"
gpg --homedir "$home" --batch --quiet --import "$key" 2> /dev/null
gpg --homedir "$home" --batch --export "$fingerprints" > "$root/usr/share/pacman/keyrings/glyndor.gpg"
printf '%s:4:\n' "$fingerprints" > "$root/usr/share/pacman/keyrings/glyndor-trusted"
: > "$root/usr/share/pacman/keyrings/glyndor-revoked"
chmod 644 "$root"/usr/share/pacman/keyrings/*
install -m 644 /dev/null "$root/.INSTALL"
cat > "$root/.INSTALL" <<'INSTALL'
post_install() {
	pacman-key --populate glyndor
}

post_upgrade() {
	pacman-key --populate glyndor
}
INSTALL
chmod 644 "$root/.INSTALL"
size="$(du -sb "$root/usr" | cut -f1)"
cat > "$root/.PKGINFO" <<PKGINFO
pkgname = glyndor-keyring
pkgbase = glyndor-keyring
pkgver = $pkgver-1
pkgdesc = The key that signs the Glyndor pacman repository
url = https://pacman.glyndor.net
builddate = $epoch
packager = Glyndor <noreply@glyndor.net>
size = $size
arch = any
license = MIT
depend = pacman
PKGINFO
chmod 644 "$root/.PKGINFO"
mkdir -p "$out"
file="glyndor-keyring-$pkgver-1-any.pkg.tar.zst"
(
	cd "$root"
	tar --sort=name --format=gnu --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --no-recursion -cf - \
		.PKGINFO .INSTALL usr usr/share usr/share/pacman usr/share/pacman/keyrings \
		usr/share/pacman/keyrings/glyndor-revoked usr/share/pacman/keyrings/glyndor-trusted usr/share/pacman/keyrings/glyndor.gpg
) | zstd -q -19 -T1 -c > "$out/$file"
chmod 644 "$out/$file"
# Nothing else is written: what leaves a container is data nobody trusts. The host derives the name, reads the package
# with the two readers of the admission and builds the row and the .PKGINFO data itself (check-keyring.py).
echo "built $file"
