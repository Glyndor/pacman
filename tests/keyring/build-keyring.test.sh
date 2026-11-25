#!/usr/bin/env bash
#
# build-keyring.sh in the pinned Arch image: the package that carries the key of the repository is the same bytes
# every time it is built from the same inputs (two builds, seconds apart, compared), changes version and bytes when its
# inputs change, has the fields and the files that pacman-key --populate reads, is read by the two readers of the
# admission, and, installed in a real pacman with a fresh keyring, puts the key in it and trusts it.
#
# Requires: docker or podman, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
RUN="$HERE/scripts/assemble/run-in-arch.sh"
KEY="$HERE/keyring/glyndor-pacman-key.asc"
FPR=0EE5C891235BE1CAD2E0ABA477E416B24362E256
mkdir -p "$WORK/w"
chmod 777 "$WORK/w"
cp "$KEY" "$WORK/w/key.asc"
chmod 644 "$WORK/w/key.asc"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
build() { # <out name> [epoch]: builds into $WORK/w/<out name>
	bash "$RUN" scripts/keyring/build-keyring.sh "$WORK/w" --key "${KEYFILE:-/work/key.asc}" --epoch "${2:-1700000000}" --out "/work/$1"
}

check "the package is built" "0" "$(rc_of build one)"
sleep 3
check "built again three seconds later, from the same inputs" "0" "$(rc_of build two)"
F="glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst"
check "the two builds are the same bytes" "$(sha256sum "$WORK/w/one/$F" | cut -d' ' -f1)" "$(sha256sum "$WORK/w/two/$F" | cut -d' ' -f1)"
check "and nothing else is written beside the package: no row, no data of .PKGINFO, whatever a container could claim" "$F" "$(cd "$WORK/w/one" && echo *)"
check "the version is 1.0.<epoch>" "yes" "$([ -f "$WORK/w/one/glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst" ] && echo yes || echo no)"
check "another epoch is another version, and other bytes" "1" "$(build three 1700000001 > /dev/null 2>&1; [ ! -f "$WORK/w/three/$F" ] && [ -f "$WORK/w/three/glyndor-keyring-1.0.1700000001-1-any.pkg.tar.zst" ] && echo 1 || echo 0)"
check "it lists .PKGINFO and .INSTALL first, then the key, the trust and the revocations" \
	".PKGINFO
.INSTALL
usr/
usr/share/
usr/share/pacman/
usr/share/pacman/keyrings/
usr/share/pacman/keyrings/glyndor-revoked
usr/share/pacman/keyrings/glyndor-trusted
usr/share/pacman/keyrings/glyndor.gpg" "$(zstd -dc -q "$WORK/w/one/$F" | tar -t)"
check "every entry has the time of the epoch and owner 0" "0" "$(zstd -dc -q "$WORK/w/one/$F" | tar -tv --full-time | grep -v -c -e 'root/root\|0/0' -e '2023-11-14 22:13:20' || true)"
check ".PKGINFO says the name, any architecture and the vendor" "3" "$(zstd -dc -q "$WORK/w/one/$F" | tar -xO .PKGINFO | grep -c -x -e 'pkgname = glyndor-keyring' -e 'arch = any' -e 'packager = Glyndor <noreply@glyndor.net>')"
check "the trust file trusts the fingerprint of the key and nothing else" "$FPR:4:" "$(zstd -dc -q "$WORK/w/one/$F" | tar -xO usr/share/pacman/keyrings/glyndor-trusted)"
check "the revocations are empty" "0" "$(zstd -dc -q "$WORK/w/one/$F" | tar -xO usr/share/pacman/keyrings/glyndor-revoked | wc -c)"
check "the keyring file holds the key of the repository" "$FPR" "$(zstd -dc -q "$WORK/w/one/$F" | tar -xO usr/share/pacman/keyrings/glyndor.gpg | gpg --batch --with-colons --import-options show-only --import 2> /dev/null | awk -F: '$1 == "fpr" { print $10 }')"

echo "-- the two readers of the admission accept it"
check "package-reader.py reads it" "0" "$(rc_of python3 -I "$HERE/scripts/admit/package-reader.py" --no-paths "$WORK/w/one/$F")"
check "and the packager is the one the channel's own packages carry" "1" "$(grep -c 'noreply@glyndor.net' "$WORK/last.out")"

echo "-- what is refused"
check "an epoch that is not a number" "2" "$(rc_of build bad1 soon)"
check "an epoch of too few digits" "2" "$(rc_of build bad2 12345)"
printf 'not a key' > "$WORK/w/notkey.asc"; chmod 644 "$WORK/w/notkey.asc"
check "a file that is not a key" "1" "$(KEYFILE=/work/notkey.asc rc_of build bad3)"
cat "$KEY" "$KEY" > "$WORK/w/two.asc"; chmod 644 "$WORK/w/two.asc"
check "two keys in the file" "1" "$(KEYFILE=/work/two.asc rc_of build bad4)"
check "an output folder that exists" "2" "$(rc_of build one)"
check "an option that is not known" "2" "$(rc_of bash "$RUN" scripts/keyring/build-keyring.sh "$WORK/w" --nope x)"

echo "-- installed in a real pacman with a fresh keyring"
cat > "$WORK/w/install.sh" <<'SH'
set -e
pacman-key --init > /dev/null 2>&1
pacman -U --noconfirm /work/one/glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst > /work/install.log 2>&1
pacman-key --list-keys 0EE5C891235BE1CAD2E0ABA477E416B24362E256 > /work/list.log 2>&1
pacman-key --finger 0EE5C891235BE1CAD2E0ABA477E416B24362E256 > /work/finger.log 2>&1
SH
chmod 644 "$WORK/w/install.sh"
image="$(bash "$HERE/scripts/assemble/arch-image.sh")"
engine=docker
command -v docker > /dev/null && timeout 60 docker info > /dev/null 2>&1 || engine=podman
check "pacman -U installs the package" "0" "$(rc_of "$engine" run --rm --network none --volume "$WORK/w:/work:rw" "$image" bash /work/install.sh)"
check "the key is in the keyring of pacman" "1" "$(grep -c "^      $FPR\$" "$WORK/w/list.log" || true)"
check "and it is trusted fully, by the trust file of the package" "1" "$(grep -c '\[  full  \]' "$WORK/w/list.log" || true)"

finish
