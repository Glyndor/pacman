#!/usr/bin/env bash
#
# list-package.sh, in the pinned Arch image: the listing and the .PKGINFO that bsdtar (the reader pacman uses on the
# host) gives for a package. What the admission compares with its own reading comes from here, so the format is
# pinned and a package bsdtar cannot read is a failure and not an empty listing.
#
# Requires: docker or podman, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
RUN="$HERE/scripts/assemble/run-in-arch.sh"
mkdir -p "$WORK/w/out"
chmod -R a+rwX "$WORK/w"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
list() { # <package file>: lists it in the image, the result in $WORK/w/out
	rm -rf "$WORK/w/out"; mkdir "$WORK/w/out"; chmod a+rwx "$WORK/w/out"
	cp "$1" "$WORK/w/package.pkg.tar.zst"; chmod a+r "$WORK/w/package.pkg.tar.zst"
	bash "$RUN" scripts/admit/list-package.sh "$WORK/w" /work/package.pkg.tar.zst /work/out
}

python3 -I "$FIXTURES/mkpkg.py" "$WORK/p.pkg.tar.zst" acme 1.2.3-1 x86_64 --makepkg-layout --symlink usr/bin/a=/usr/lib/a \
	--hardlink usr/b=usr/share/acme/README --member 'usr/dir with space/f=x'
check "a package is listed" "0" "$(rc_of list "$WORK/p.pkg.tar.zst")"
check "the listing has the symbolic link as 'name -> target'" "1" "$(grep -c '^l.* usr/bin/a -> /usr/lib/a$' "$WORK/w/out/list.txt" || true)"
check "and the hard link as 'name link to target'" "1" "$(grep -c '^h.* usr/b link to usr/share/acme/README$' "$WORK/w/out/list.txt" || true)"
check "a name with spaces is kept whole" "1" "$(grep -c ' usr/dir with space/f$' "$WORK/w/out/list.txt" || true)"
check ".PKGINFO is the bytes of the member" "pkgname = acme" "$(head -1 "$WORK/w/out/pkginfo")"
check "the version of bsdtar is written down" "1" "$(grep -c '^bsdtar ' "$WORK/w/out/version" || true)"
printf 'not an archive' > "$WORK/bad.pkg.tar.zst"
check "a file that is not an archive is a failure" "1" "$(rc_of list "$WORK/bad.pkg.tar.zst")"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/nopkginfo.pkg.tar.zst" acme 1.2.3-1 x86_64 --no-pkginfo
check "a package with no .PKGINFO is a failure, not an empty .PKGINFO" "1" "$(rc_of list "$WORK/nopkginfo.pkg.tar.zst")"
# read whole into a file first: `head` closing the pipe early can kill zstd with SIGPIPE, and under pipefail that failed the suite now and then
zstd -dc -q "$WORK/p.pkg.tar.zst" > "$WORK/p.tar"
head -c 700 "$WORK/p.tar" | zstd -q -f -o "$WORK/cut.pkg.tar.zst"
check "an archive that is cut short is a failure" "1" "$(rc_of list "$WORK/cut.pkg.tar.zst")"

finish
