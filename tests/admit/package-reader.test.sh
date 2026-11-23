#!/usr/bin/env bash
#
# package-reader.py: a package is read by tarfile and by the bsdtar of the pinned Arch image, and has to be the same
# archive for both. Each package below is built by hand to be read differently by two readers or to hide something
# after the end of the archive; the real package of makepkg that has to pass is admit-makepkg.test.sh.
#
# Requires: docker or podman, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
READER="$HERE/scripts/admit/package-reader.py"
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
pkg() { python3 -I "$FIXTURES/mkpkg.py" "$WORK/p.pkg.tar.zst" acme 1.2.3-1 x86_64 "$@"; }
read_it() { python3 -I "$READER" "$WORK/p.pkg.tar.zst"; }

pkg --makepkg-layout
check "an ordinary package is read" "0" "$(rc_of read_it)"
check "the fields come out as JSON" "acme" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["pkgname"][0])' "$WORK/last.out")"
check "no argument is a usage error" "2" "$(rc_of python3 -I "$READER")"
check "a file that is not zstd is refused before a decompressor sees it" "1" "$(printf 'not zstd' > "$WORK/p.pkg.tar.zst"; rc_of read_it)"
pkg --global-pax;               check "a global pax header" "1" "$(rc_of read_it)"
pkg --dir-pax-size usr/x=4096;  check "a folder with a pax size" "1" "$(rc_of read_it)"
pkg --typeflag 7=usr/c;         check "a contiguous member" "1" "$(rc_of read_it)"
pkg --typeflag S=usr/s;         check "a sparse member" "1" "$(rc_of read_it)"
pkg --typeflag Z=usr/z;         check "an unknown type" "1" "$(rc_of read_it)"
pkg --device dev/x;             check "a device" "1" "$(rc_of read_it)"
pkg --huge-header x;            check "a pax header that claims two gigabytes" "1" "$(rc_of read_it)"
check "and is refused before it is read" "1" "$(says 'extended header of')"
pkg --huge-header L;            check "a GNU long name header that claims two gigabytes" "1" "$(rc_of read_it)"
check "and says so" "1" "$(says 'long name header of')"
pkg --junk-trailer 1;           check "one byte after the end of the archive" "1" "$(rc_of read_it)"
pkg --tar-trailer;              check "a second archive after the first" "1" "$(rc_of read_it)"
pkg --no-end-mark;              check "an archive with no end mark" "1" "$(rc_of read_it)"
pkg --second-pkginfo;           check "two .PKGINFO" "1" "$(rc_of read_it)"
pkg --late-pkginfo;             check ".PKGINFO after an ordinary entry" "1" "$(rc_of read_it)"
pkg --zero-trailer 4096;        check "zero bytes after the end mark are fine" "0" "$(rc_of read_it)"
pkg --hardlink usr/b=/etc/passwd; check "a hard link out of the tree" "1" "$(rc_of read_it)"
pkg --raw-member '../x';        check "a name with .." "1" "$(rc_of read_it)"
pkg --symlink usr/l=/usr/lib/x --hardlink usr/h=usr/share/acme/README; check "ordinary links are fine" "0" "$(rc_of read_it)"
pkg;                            check "the engine of the host's reader is named when it is missing" "2" "$(CONTAINER_ENGINE=/nonexistent/engine rc_of read_it)"

echo "-- .PKGINFO is read strictly"
refused_with() { # <words>: the reader refused (status 1) and said these words, not a crash
	local rc
	rc="$(rc_of read_it)"
	[ "$rc" = 1 ] && [ "$(says "$1")" -ge 1 ] && echo ok || echo "rc=$rc"
}
pkg --escapes --append 'pkgdesc=a\x00b'; check "a NUL byte in a field" "ok" "$(refused_with 'control character')"
pkg --escapes --append 'pkgdesc=a\rb'; check "a carriage return" "ok" "$(refused_with 'control character')"
pkg --escapes --append 'pkgdesc=a\x0bb'; check "a vertical tab" "ok" "$(refused_with 'control character')"
pkg --escapes --append 'pkgdesc=a\x0cb'; check "a form feed" "ok" "$(refused_with 'control character')"
pkg --escapes --append 'pkgdesc=a\tb'; check "a tab" "ok" "$(refused_with 'control character')"
pkg --escapes --append 'pkgdesc=a\x7fb'; check "a DEL" "ok" "$(refused_with 'control character')"
pkg --append 'evil=1'; check "a key this channel does not know" "ok" "$(refused_with 'does not know: evil')"
pkg --append 'PkgDesc=x'; check "a key in upper case" "ok" "$(refused_with 'is not')"
pkg --append 'conflicts=glibc'; check "the plural spelling of conflict is read, and given to the check of the relations" "0" "$(rc_of read_it)"
check "as the key it is" "1" "$(grep -c '"conflicts": \["glibc"\]' "$WORK/last.out" || true)"
pkg --append 'pkgname=acme'; check "a key that may be set once, set twice" "ok" "$(refused_with 'sets pkgname twice')"
pkg --member '.PKGINFO=pkgname = acme
pkgver = 1.2.3-1' --no-pkginfo
check "a .PKGINFO that does not end with a line feed" "ok" "$(refused_with 'does not end with a line feed')"
pkg --member '.PKGINFO=pkgname = acme
 pkgver = 1.2.3-1
' --no-pkginfo
check "a line with a leading space" "ok" "$(refused_with 'is not')"
pkg --member '.PKGINFO=pkgname = acme

pkgver = 1.2.3-1
' --no-pkginfo
check "a blank line" "ok" "$(refused_with 'is not')"
pkg --member '.PKGINFO=# Generated by makepkg 7.1.0
pkgname = acme
pkgver = 1.2.3-1
' --no-pkginfo
check "the comment makepkg writes is accepted" "0" "$(rc_of read_it)"
pkg --append 'depend=bad name!'; check "a dependency that is not a name" "ok" "$(refused_with 'not a package name')"
pkg --append 'depend=libseccomp.so=2-64'; check "a soname dependency" "0" "$(rc_of read_it)"
pkg --append 'optdepend=podman: to run'; check "an optional dependency with its reason" "0" "$(rc_of read_it)"
pkg --append 'optdepend=Bad: x'; check "an optional dependency that is not a name" "ok" "$(refused_with 'not a package name')"
pkg --append 'provides=../x'; check "a provides that is a path" "ok" "$(refused_with 'not a package name')"
pkg --append 'replaces=a;b'; check "a replaces with a shell character" "ok" "$(refused_with 'not a package name')"
pkg --append 'makedepend=;rm'; check "a make dependency with a shell character" "ok" "$(refused_with 'not a package name')"
pkg --append 'provides=acme=1.2.3-1'; check "a provides with a version" "0" "$(rc_of read_it)"
pkg --append 'depend=podman>=6.2.0'; check "a dependency with a range" "0" "$(rc_of read_it)"

echo "-- the bounds"
pkginfo_of() { python3 -I - "$1" "$WORK/pkginfo" <<'PY'
import sys
base = "pkgname = acme\npkgver = 1.2.3-1\n"
open(sys.argv[2], "w").write(base + "#" * (int(sys.argv[1]) - len(base) - 1) + "\n")
PY
}
pkginfo_of 65536; pkg --member ".PKGINFO=@$WORK/pkginfo" --no-pkginfo
check "a .PKGINFO of exactly 64 KiB" "0" "$(rc_of read_it)"
pkginfo_of 65537; pkg --member ".PKGINFO=@$WORK/pkginfo" --no-pkginfo
check "a .PKGINFO of 64 KiB and one byte" "ok" "$(refused_with 'at most 64 KiB')"
many() { python3 -I - "$1" "$WORK/p.pkg.tar.zst" <<'PY'
import io, subprocess, sys, tarfile
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
	body = b"pkgname = acme\npkgver = 1.2.3-1\n"
	info = tarfile.TarInfo(".PKGINFO")
	info.size = len(body)
	archive.addfile(info, io.BytesIO(body))
	for i in range(int(sys.argv[1])):
		archive.addfile(tarfile.TarInfo(f"d/{i}"))
subprocess.run(["zstd", "-q", "-1", "-f", "-o", sys.argv[2]], input=buffer.getvalue(), check=True)
PY
}
many 99999; check "a package with exactly 100000 entries" "0" "$(rc_of read_it)"
many 100000; check "a package with 100001 entries" "ok" "$(refused_with 'more than 100000 entries')"
python3 -I - "$WORK/p.pkg.tar.zst" <<'PY'
import io, subprocess, sys, tarfile
class Zeros(io.RawIOBase):
	def __init__(self, n): self.n = n
	def readable(self): return True
	def readinto(self, b):
		take = min(len(b), self.n)
		b[:take] = bytes(take)
		self.n -= take
		return take
proc = subprocess.Popen(["zstd", "-q", "-1", "-f", "-o", sys.argv[1]], stdin=subprocess.PIPE)
with tarfile.open(fileobj=proc.stdin, mode="w|") as archive:
	body = b"pkgname = acme\npkgver = 1.2.3-1\n"
	info = tarfile.TarInfo(".PKGINFO")
	info.size = len(body)
	archive.addfile(info, io.BytesIO(body))
	big = tarfile.TarInfo("usr/zeros")
	big.size = 2 * 1024 ** 3 + 4096
	archive.addfile(big, Zeros(big.size))
proc.stdin.close()
proc.wait()
PY
check "a package that unpacks to more than 2 GiB" "ok" "$(refused_with 'unpacks to more than')"

finish
