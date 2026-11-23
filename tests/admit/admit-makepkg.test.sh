#!/usr/bin/env bash
#
# A package made by the real makepkg of the pinned Arch image, split like Podman's, must pass the admission, and the
# same package with one relation changed must not. This is the check that the parser reads the keys that makepkg
# writes (`depend`, `conflict`, `pkgbase`, `xdata`, `.BUILDINFO` and `.MTREE` before `.PKGINFO`) and not the ones a
# reader would guess, which a hand-made package cannot prove.
#
# It needs a container engine and the network: makepkg wants fakeroot, which the image does not carry, so the image is
# brought up to date and fakeroot installed in a container that is thrown away. It fails without them and does not
# pretend to pass.
#
# Requires: docker or podman, network, python3 with cryptography, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
engine="${CONTAINER_ENGINE:-}"
if [ -z "$engine" ]; then
	for candidate in docker podman; do
		if command -v "$candidate" > /dev/null && timeout 60 "$candidate" info > /dev/null 2>&1; then
			engine="$candidate"
			break
		fi
	done
fi
[ -n "$engine" ] || { echo "FAIL  neither docker nor podman answers"; exit 1; }
image="$(grep -v -e '^#' -e '^$' "$HERE/scripts/assemble/arch-image.txt")"
# shellcheck disable=SC2153 # WORK comes from lib.sh
KEYS="$WORK/keys"
new_key "$KEYS"
mkdir -p "$WORK/mk/out"
cp "$FIXTURES/PKGBUILD.split" "$WORK/mk/PKGBUILD"
chmod -R a+rwX "$WORK/mk"
built=0
for _ in 1 2 3; do
	if timeout 1500 "$engine" run --rm --volume "$WORK/mk:/work:rw" "$image" bash -c '
		set -e
		pacman -Syu --noconfirm --needed fakeroot > /dev/null 2>&1
		useradd -m builder
		install -d -o builder /home/builder/b
		cp /work/PKGBUILD /home/builder/b/PKGBUILD
		chown builder /home/builder/b/PKGBUILD
		su builder -c "cd /home/builder/b && PACKAGER=\"Glyndor <noreply@glyndor.net>\" makepkg -f --nodeps --skipinteg > /dev/null 2>&1"
		cp /home/builder/b/*.pkg.tar.zst /work/out/
		chmod a+r /work/out/*
	' > "$WORK/makepkg.log" 2>&1; then
		built=1
		break
	fi
done
check "makepkg built the split package (three tries, the mirrors are the network's)" "1" "$built"
if [ "$built" -ne 1 ]; then tail -20 "$WORK/makepkg.log"; finish; exit 1; fi
check "it made two members" "2" "$(find "$WORK/mk/out" -name '*.pkg.tar.zst' | wc -l)"
printf 'podman\tpodman\tx86_64\tnetavark,container-network-stack\npodman\tpodman-docker\tany\tdocker\n' > "$WORK/products.txt"
: > "$WORK/no-required"

# release <folder>: the two members as a release carries them, signed
release() {
	rm -rf "$1"
	mkdir -p "$1"
	cp "$WORK/mk/out/"*.pkg.tar.zst "$1/"
	local f
	for f in "$1"/*.pkg.tar.zst; do python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$f"; done
}
admit() { # <release folder>
	local repo_dir="$WORK/r/podman"
	rm -rf "$WORK/r" "$WORK/dl" "$WORK/out.tsv"
	mkdir -p "$repo_dir"
	cp -a "$1" "$repo_dir/v1.2.3"
	FAKE_RELEASES="$WORK/r" bash "$FIXTURES/fake-gh" release view v1.2.3 --repo Glyndor/podman --json assets > "$WORK/listing.json"
	cp -a "$1" "$WORK/dl"
	python3 -I "$HERE/scripts/admit/admit.py" check --products "$WORK/products.txt" --repo podman --tag v1.2.3 --assets "$WORK/listing.json" \
		--dir "$WORK/dl" --ed25519-keys "$KEYS/release.b64" --pq-required "$WORK/no-required" --out "$WORK/out.tsv"
}
release "$WORK/good"
check "the two members of the real split package are admitted" "0" "$(admit "$WORK/good" > "$WORK/last.out" 2>&1; echo $?)"
check "and the manifest lists both" "2" "$(wc -l < "$WORK/out.tsv")"
check "podman-docker is the one that depends on podman at the exact version" "1" \
	"$(zstd -dc -q "$WORK/mk/out/podman-docker-1.2.3-1-any.pkg.tar.zst" | tar -xO .PKGINFO | grep -c '^depend = podman=1.2.3-1$')"
check "and its .PKGINFO names the base and the split type" "2" "$(zstd -dc -q "$WORK/mk/out/podman-docker-1.2.3-1-any.pkg.tar.zst" | tar -xO .PKGINFO | grep -c -e '^pkgbase = podman$' -e '^xdata = pkgtype=split$')"

# the same package, remade with one relation that the products file does not allow
mangle() { # <sed expression on .PKGINFO>: a copy of podman-docker whose .PKGINFO is changed
	local work="$WORK/mangle"
	rm -rf "$work"
	mkdir -p "$work"
	zstd -dc -q "$WORK/mk/out/podman-docker-1.2.3-1-any.pkg.tar.zst" | tar -x -C "$work"
	sed -i "$1" "$work/.PKGINFO"
	(cd "$work" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf - .BUILDINFO .MTREE .PKGINFO usr | zstd -q -f -o "$WORK/mangled.pkg.tar.zst")
	release "$WORK/bad"
	cp "$WORK/mangled.pkg.tar.zst" "$WORK/bad/podman-docker-1.2.3-1-any.pkg.tar.zst"
	python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$WORK/bad/podman-docker-1.2.3-1-any.pkg.tar.zst"
	admit "$WORK/bad" > "$WORK/last.out" 2>&1 || return $?
}
rc_of() { local rc=0; "$@" || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
# shellcheck disable=SC2016 # sed programs, not shell
check "a hostile 'conflict = openssl' added by hand is refused" "1" "$(rc_of mangle '$a conflict = openssl')"
check "and the refusal names the conflict" "1" "$(says 'lists openssl in conflict')"
# shellcheck disable=SC2016
check "a hostile 'replaces = glibc' is refused" "1" "$(rc_of mangle '$a replaces = glibc')"
check "and the refusal names what it replaces" "1" "$(says 'lists glibc in replaces')"
check "a dependency on podman at another version is refused" "1" "$(rc_of mangle 's/^depend = podman=1.2.3-1$/depend = podman>=1/')"
check "and the refusal asks for the exact version" "1" "$(says 'exactly')"
check "a vendor that is not Glyndor is refused" "1" "$(rc_of mangle 's/^packager = .*/packager = Somebody <x@example.org>/')"
check "and the refusal names the vendor" "1" "$(says 'packager')"

finish
