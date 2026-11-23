#!/usr/bin/env bash
#
# admit.py check: what the channel decides about the files it downloaded. A package is admitted only when
# the release key verified its exact bytes and the fields read from those same bytes say what the
# file name says. Each planted release below breaks one thing: a bad or foreign signature, another
# product's name, a rebuilt old version, the wrong vendor, a relation that replaces somebody else's
# package, a member that escapes its tree, an archive bomb, a file that is not what the listing said.
#
# The packages are tiny and built here (tests/fixtures/pacman/mkpkg.py), signed with a key made for the run.
#
# Requires: python3 with cryptography, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
ADMIT="$HERE/scripts/admit/admit.py"
KEYS="$WORK/keys"
OTHER="$WORK/other-keys"
new_key "$KEYS"
new_key "$OTHER"
printf 'acme\tacme\tx86_64\t-\n' > "$WORK/products.txt"
: > "$WORK/no-required"
N=0
P="acme-1.2.3-1-x86_64.pkg.tar.zst"

# release <name>: a fresh release folder for acme v1.2.3 at $REL, empty
release() { N=$((N + 1)); REL="$WORK/r$N/acme/v1.2.3"; mkdir -p "$REL"; DL="$WORK/r$N/dl"; }
# attempt [extra admit.py options...]: download what the listing names into DL, then check it
attempt() {
	rm -rf "$DL" "$WORK/out.tsv"
	cp -a "$REL" "$DL"
	listing "$REL" > "$WORK/listing.json"
	[ -z "${AFTER:-}" ] || ( cd "$DL" && eval "$AFTER" )
	python3 -I "$ADMIT" check --products "$WORK/products.txt" --repo "${REPO:-acme}" --tag v1.2.3 --assets "$WORK/listing.json" \
		--dir "$DL" --ed25519-keys "${KEYFILE:-$KEYS/release.b64}" --pq-required "$WORK/no-required" --out "$WORK/out.tsv" "$@" 2>&1
}
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	# a traceback is a crash and never a verdict
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
says() { grep -c -- "$1" "$WORK/last.out" || true; }
good() { release; add_pkg "$REL" "$KEYS" acme 1.2.3-1 x86_64 "$@"; }

good
check "a package signed by the release key with the right fields is admitted" "0" "$(rc_of attempt)"
check "and the manifest says repository, package, pkgver, arch, file, size, sha256, second signature" \
	"acme	acme	1.2.3-1	x86_64	$P	$(stat -c%s "$REL/$P")	$(sha256sum "$REL/$P" | cut -d' ' -f1)	no" "$(cat "$WORK/out.tsv")"

echo "-- signatures"
good; rc=0; python3 -I "$FIXTURES/release-key.py" garbage "$REL/$P.sig"
check "a signature that is not one is refused" "1" "$(rc_of attempt)"
check "and the refusal names the signature" "1" "$(says 'not signed by the release key')"
good; python3 -I "$FIXTURES/release-key.py" sign "$OTHER" "$REL/$P"
check "a package signed by another key is refused" "1" "$(rc_of attempt)"
good; head -c 63 "$REL/$P.sig" > "$WORK/short" && cp "$WORK/short" "$REL/$P.sig"
check "a signature of 63 bytes is refused" "1" "$(rc_of attempt)"
good; head -c 4097 /dev/zero > "$REL/$P.sig"
check "a signature of 4097 bytes is refused before it is read whole" "1" "$(rc_of attempt)"
good; AFTER="printf x >> $P"
check "a package changed after it was signed is refused" "1" "$(rc_of attempt)"
good; AFTER=""
cat "$OTHER/release.b64" "$KEYS/release.b64" > "$WORK/two.b64"
check "a key file with a second key line still verifies with the right one" "0" "$(KEYFILE="$WORK/two.b64" rc_of attempt)"
check "a key file with a carriage return is a configuration error, not a refusal" "2" \
	"$(printf '%s\r\n' "$(cat "$KEYS/release.b64")" > "$WORK/crlf.b64"; KEYFILE="$WORK/crlf.b64" rc_of attempt)"
check "a key file with no key is a configuration error" "2" "$(: > "$WORK/empty.b64"; KEYFILE="$WORK/empty.b64" rc_of attempt)"
check "a key file that is not there is a configuration error" "2" "$(KEYFILE="$WORK/none.b64" rc_of attempt)"

echo "-- the second signature (ML-DSA-65), the cases that need no ML-DSA library"
good; head -c 3309 /dev/zero > "$REL/$P.mldsa65.sig"
check "a second signature with no ML-DSA key configured is refused" "1" "$(rc_of attempt)"
check "and says that it cannot be checked" "1" "$(says 'cannot be checked')"
check "a second signature of the wrong length is refused even with a key configured" "1" \
	"$(python3 -I -c 'import base64,sys;print(base64.b64encode(bytes(1952)).decode())' > "$WORK/pq.b64"; rc_of attempt --mldsa-keys "$WORK/pq.b64")"
good; printf 'acme\n' > "$WORK/required"
check "a required second signature that is absent is refused" "1" "$(rc_of attempt --pq-required "$WORK/required")"
check "and says that the hybrid signature is required" "1" "$(says 'hybrid release signature is required')"
printf 'acme\tacme\tx86_64\t-\nlater\tlib\tany\t-\n' > "$WORK/products.txt"
printf 'lib\n' > "$WORK/required"
check "a requirement for another package of the products file does not apply" "0" "$(rc_of attempt --pq-required "$WORK/required")"
printf 'Acme # since 2\n' > "$WORK/required"
check "a malformed required list is a configuration error and does not switch the requirement off" "2" "$(rc_of attempt --pq-required "$WORK/required")"
check "a required list that is not there is a configuration error, not an empty list" "2" "$(rc_of attempt --pq-required "$WORK/missing-list")"
check "and says that it cannot read it" "1" "$(says 'second signature')"
mkdir -p "$WORK/a-folder"
check "a required list that is a folder is a configuration error" "2" "$(rc_of attempt --pq-required "$WORK/a-folder")"
printf 'nothing-declared\n' > "$WORK/required"
check "an entry that is no package of the products file is refused, not ignored" "2" "$(rc_of attempt --pq-required "$WORK/required")"
check "and says the requirement would apply to nothing" "1" "$(says 'apply to nothing')"
: > "$WORK/required"
check "an empty required list changes nothing" "0" "$(rc_of attempt --pq-required "$WORK/required")"

echo "-- the fields of .PKGINFO, read from the verified bytes"
good --set packager="Somebody <x@example.org>"; check "another vendor is refused" "1" "$(rc_of attempt)"
good --drop packager; check "a package with no vendor is refused" "1" "$(rc_of attempt)"
good --set pkgname=evil; check "another pkgname than the file's is refused" "1" "$(rc_of attempt)"
good --set pkgver=1.2.2-1; check "a rebuilt old version under a new name is refused" "1" "$(rc_of attempt)"
good --set pkgver=1.2.3-2; check "another revision inside than in the name is refused" "1" "$(rc_of attempt)"
good --set arch=any; check "an architecture inside that is not the one in the name is refused" "1" "$(rc_of attempt)"
good --set pkgbase=other; check "another pkgbase is refused" "1" "$(rc_of attempt)"
good --set pkgbase=acme; check "pkgbase equal to the name is accepted" "0" "$(rc_of attempt)"
good --append pkgname=acme; check "pkgname twice is refused" "1" "$(rc_of attempt)"
check "and says that it is set twice" "1" "$(says 'sets pkgname twice')"
good --set size=abc; check "a size that is not a number is refused" "1" "$(rc_of attempt)"
good --set replaces=linux; check "a package that replaces another one is refused" "1" "$(rc_of attempt)"
good --append conflict=glibc; check "a package with 'conflict = glibc' (the key as pacman spells it) is refused" "1" "$(rc_of attempt)"
check "and names the key" "1" "$(says 'in conflict')"
good --append conflicts=glibc; check "a package with the plural spelling is refused too" "1" "$(rc_of attempt)"
good --append replaces=glibc; check "a package with 'replaces = glibc' is refused" "1" "$(rc_of attempt)"
good --append conflict=acme; check "a package that conflicts with itself is accepted" "0" "$(rc_of attempt)"
good --set provides=docker; check "a relation that its line of the products file does not name is refused" "1" "$(rc_of attempt)"
good --set provides=acme=1.2.3-1; check "providing itself with a version is accepted" "0" "$(rc_of attempt)"
good --append depend=podman'>=6.2.0' --append optdepend=foo; check "free dependency fields are accepted" "0" "$(rc_of attempt)"
good --set pkgname=acme --set 'bad line'; check "a .PKGINFO line that is not key = value is refused" "1" "$(rc_of attempt)"
# podman is the one product whose line names relations: what it may replace, provide and conflict with
printf 'podman\tpodman\tx86_64\tnetavark,container-network-stack,podman-remote\n' > "$WORK/products.txt"
N=$((N + 1)); REL="$WORK/r$N/podman/v1.2.3"; DL="$WORK/r$N/dl"; REPO=podman
add_pkg "$REL" "$KEYS" podman 1.2.3-1 x86_64 --set replaces=netavark --set provides=container-network-stack=2 --set conflicts=podman-remote
check "podman may replace, provide and conflict with exactly the names its line lists" "0" "$(rc_of attempt)"
N=$((N + 1)); REL="$WORK/r$N/podman/v1.2.3"; DL="$WORK/r$N/dl"
add_pkg "$REL" "$KEYS" podman 1.2.3-1 x86_64 --set replaces=netavark --set replaces=linux
check "and one more replaced name is refused" "1" "$(rc_of attempt)"
REPO=acme
printf 'acme\tacme\tx86_64\t-\n' > "$WORK/products.txt"

# a split package, as makepkg writes it for pkgbase=podman: two members, one base, a dependency on the other
printf 'podman\tpodman\tx86_64\tnetavark\npodman\tpodman-docker\tany\tdocker\n' > "$WORK/products.txt"
split() { # <podman-docker options...>: a release with both members in $REL
	N=$((N + 1)); REL="$WORK/r$N/podman/v1.2.3"; DL="$WORK/r$N/dl"; REPO=podman
	add_pkg "$REL" "$KEYS" podman 1.2.3-1 x86_64 --makepkg-layout --set pkgbase=podman --append xdata=pkgtype=split
	add_pkg "$REL" "$KEYS" podman-docker 1.2.3-1 any --makepkg-layout --set pkgbase=podman --append xdata=pkgtype=split "$@"
}
split --append depend=podman=1.2.3-1 --append provides=docker --append conflict=docker
check "the two members of a split package, in makepkg's layout, are admitted" "0" "$(rc_of attempt)"
check "and both are in the manifest" "2" "$(wc -l < "$WORK/out.tsv")"
split --append 'depend=podman>=1.2.3'
check "a member that depends on the other with >= instead of the exact version is refused" "1" "$(rc_of attempt)"
check "and says that the exact version is required" "1" "$(says 'must depend on podman=1.2.3-1 exactly')"
split --append depend=podman=1.2.2-1
check "a member that depends on the other at another version is refused" "1" "$(rc_of attempt)"
split --append depend=podman
check "a member that depends on the other with no version is refused" "1" "$(rc_of attempt)"
split --append depend=podman=1.2.3-1 --append conflict=openssl
check "a split member with conflict = openssl is refused" "1" "$(rc_of attempt)"
split --append depend=podman=1.2.3-1 --append replaces=glibc
check "a split member with replaces = glibc is refused" "1" "$(rc_of attempt)"
split --append depend=podman=1.2.3-1 --set pkgbase=evil
check "a pkgbase that is neither the package nor another one of the product is refused" "1" "$(rc_of attempt)"
split --append depend=openssl --append depend=podman=1.2.3-1
check "a dependency on a package of another product is free" "0" "$(rc_of attempt)"
REPO=acme
printf 'acme\tacme\tx86_64\t-\n' > "$WORK/products.txt"

echo "-- nothing but the end of the archive follows the last member"
good --zero-trailer 1048576; check "a megabyte of zero bytes after the end mark is accepted" "0" "$(rc_of attempt)"
good --junk-trailer 1; check "one non-zero byte after the end of the archive is refused" "1" "$(rc_of attempt)"
check "and says there is data after the end of the archive" "1" "$(says 'data after the end of the archive')"
good --tar-trailer; check "a second archive after the first is refused" "1" "$(rc_of attempt)"
good --junk-trailer 100; check "a cut header (100 bytes) after the end is refused" "1" "$(rc_of attempt)"
good --junk-trailer 512; check "a block that is not a header after the end is refused" "1" "$(rc_of attempt)"
good --no-end-mark; check "an archive that ends without its two zero blocks is refused" "1" "$(rc_of attempt)"
check "and says so" "1" "$(says 'two zero blocks')"

echo "-- where tarfile and the reader of the host could differ"
good --global-pax; check "a global pax header is refused" "1" "$(rc_of attempt)"
check "and says so" "1" "$(says 'global pax header')"
good --dir-pax-size usr/trap=4096; check "a folder whose pax header gives it a size is refused" "1" "$(rc_of attempt)"
check "and says that a member that is not a regular file has a size" "1" "$(says 'has a size')"
good --typeflag 7=usr/contiguous; check "a contiguous file (type 7), read as regular by one reader and not by the other, is refused" "1" "$(rc_of attempt)"
good --typeflag S=usr/sparse; check "a sparse member is refused" "1" "$(rc_of attempt)"
good --typeflag Z=usr/unknown; check "a member of an unknown type is refused" "1" "$(rc_of attempt)"
check "and says it is not a file, folder or link" "1" "$(says 'not a file, folder or link')"
good --typeflag 6=usr/fifo; check "a pipe (type 6) is refused" "1" "$(rc_of attempt)"
good; check "an ordinary package is read the same by both readers" "0" "$(rc_of attempt)"

echo "-- .PKGINFO is read strictly"
good --escapes --append 'pkgdesc=a\x00b'; check "a NUL byte in a field is refused" "1" "$(rc_of attempt)"
check "and says it is a control character" "1" "$(says 'control character')"
good --escapes --append 'pkgdesc=a\rb'; check "a carriage return is refused" "1" "$(rc_of attempt)"
good --escapes --append 'pkgdesc=a\x0bb'; check "a vertical tab is refused" "1" "$(rc_of attempt)"
good --escapes --append 'pkgdesc=a\x0cb'; check "a form feed is refused" "1" "$(rc_of attempt)"
good --escapes --append 'pkgdesc=a\tb'; check "a tab is refused" "1" "$(rc_of attempt)"
good --append 'evil=1'; check "a key this channel does not know is refused, not ignored" "1" "$(rc_of attempt)"
check "and names the key" "1" "$(says 'does not know: evil')"
good --append 'PkgDesc=x'; check "a key in upper case is refused" "1" "$(rc_of attempt)"
good --append 'sp ace=x'; check "a key with a space is refused" "1" "$(rc_of attempt)"
good --member '.PKGINFO=pkgname = acme
pkgver = 1.2.3-1
arch = x86_64
packager = Glyndor <noreply@glyndor.net>' --no-pkginfo; check "a .PKGINFO that does not end with a line feed is refused" "1" "$(rc_of attempt)"
good --member '.PKGINFO=pkgname = acme
 pkgver = 1.2.3-1
arch = x86_64
packager = Glyndor <noreply@glyndor.net>
' --no-pkginfo; check "a line with a leading space (that a stripping reader would accept) is refused" "1" "$(rc_of attempt)"
good --member '.PKGINFO=pkgname = acme

pkgver = 1.2.3-1
arch = x86_64
packager = Glyndor <noreply@glyndor.net>
' --no-pkginfo; check "a blank line inside is refused" "1" "$(rc_of attempt)"
good --member '.PKGINFO=# Generated by makepkg 7.1.0
# using fakeroot version 1.37
pkgname = acme
pkgver = 1.2.3-1
arch = x86_64
packager = Glyndor <noreply@glyndor.net>
' --no-pkginfo; check "the comment lines makepkg writes are accepted" "0" "$(rc_of attempt)"
good --append 'depend=bad name!'; check "a dependency that is not a name is refused" "1" "$(rc_of attempt)"
good --append 'depend=libseccomp.so=2-64'; check "a soname dependency is accepted" "0" "$(rc_of attempt)"
good --append 'optdepend=podman: to run the containers'; check "an optional dependency with its reason is accepted" "0" "$(rc_of attempt)"
good --append 'optdepend=Bad Name: x'; check "an optional dependency that is not a name is refused" "1" "$(rc_of attempt)"
good --append 'provides=../x'; check "a provides that is a path is refused" "1" "$(rc_of attempt)"
good --append 'makedepend=;rm'; check "a make dependency with a shell character is refused" "1" "$(rc_of attempt)"
good --append 'backup=etc/acme.conf' --append 'license=MIT' --append 'group=glyndor'; check "backup, license and group, which makepkg writes, are accepted" "0" "$(rc_of attempt)"

echo "-- the archive"
good --raw-member '../escape'; check "a member with .. is refused" "1" "$(rc_of attempt)"
good --raw-member '/etc/cron.d/x'; check "a member with an absolute name is refused" "1" "$(rc_of attempt)"
good --raw-member 'usr/../../x'; check "a member that climbs out through the middle is refused" "1" "$(rc_of attempt)"
good --device dev/null; check "a device node is refused" "1" "$(rc_of attempt)"
good --hardlink usr/x=/etc/shadow; check "a hard link to an absolute path is refused" "1" "$(rc_of attempt)"
good --hardlink usr/x=../../etc/shadow; check "a hard link that climbs out is refused" "1" "$(rc_of attempt)"
good --symlink usr/bin/acme=/usr/lib/acme/acme; check "an ordinary symbolic link is accepted" "0" "$(rc_of attempt)"
good --makepkg-layout; check "a package in the order makepkg writes (.BUILDINFO, .MTREE, .PKGINFO) is accepted" "0" "$(rc_of attempt)"
good --late-pkginfo; check "a .PKGINFO after the first ordinary entry is refused" "1" "$(rc_of attempt)"
check "and says it is read only among the leading dot entries" "1" "$(says 'leading dot entries')"
good --second-pkginfo; check "two .PKGINFO members are refused" "1" "$(rc_of attempt)"
check "and says there are two" "1" "$(says 'two .PKGINFO')"
good --no-pkginfo; check "no .PKGINFO is refused" "1" "$(rc_of attempt)"
check "and says there is none" "1" "$(says 'has no .PKGINFO')"
good --symlink .PKGINFO=/etc/passwd --no-pkginfo; check "a .PKGINFO that is a link is refused" "1" "$(rc_of attempt)"
check "and says it must be a regular file" "1" "$(says 'not a regular file')"
good --member ".PKGINFO=$(printf 'x%.0s' $(seq 1 70000))" --no-pkginfo
check "a .PKGINFO over 64 KiB is refused" "1" "$(rc_of attempt)"
check "and says it must be at most 64 KiB" "1" "$(says 'at most 64 KiB')"
pkginfo_of() { # <size>: a .PKGINFO of exactly that many bytes, ended with a line feed, in $WORK/pkginfo
	python3 -I - "$1" "$WORK/pkginfo" <<'PY'
import sys
base = "pkgname = acme\npkgver = 1.2.3-1\narch = x86_64\npackager = Glyndor <noreply@glyndor.net>\n"
open(sys.argv[2], "w").write(base + "#" * (int(sys.argv[1]) - len(base) - 1) + "\n")
PY
}
pkginfo_of 65536
good --member ".PKGINFO=@$WORK/pkginfo" --no-pkginfo
check "a .PKGINFO of exactly 64 KiB is accepted" "0" "$(rc_of attempt)"
pkginfo_of 65537
good --member ".PKGINFO=@$WORK/pkginfo" --no-pkginfo
check "a .PKGINFO of 64 KiB and one byte is refused" "1" "$(rc_of attempt)"
good; printf 'not a zstd stream, nor a tar' > "$REL/$P"; python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$REL/$P"
check "a signed file that is not a tar.zst is refused" "1" "$(rc_of attempt)"
check "and says that it lacks the zstd magic" "1" "$(says 'zstd magic')"
good; head -c 100 "$REL/$P" > "$WORK/cut" && cp "$WORK/cut" "$REL/$P"; python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$REL/$P"
check "a signed package that is cut short is refused" "1" "$(rc_of attempt)"
check "and says it is not readable, not that it crashed" "1" "$(grep -c -e 'not a readable tar.zst' -e 'could not decompress' "$WORK/last.out" || true)"
many() { # <extra entries> <out>: .PKGINFO and that many empty files
	python3 -I - "$1" "$2" <<'PY'
import io, subprocess, sys, tarfile
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
	info = tarfile.TarInfo(".PKGINFO")
	body = b"pkgname = acme\npkgver = 1.2.3-1\narch = x86_64\npackager = Glyndor <noreply@glyndor.net>\n"
	info.size = len(body)
	archive.addfile(info, io.BytesIO(body))
	for i in range(int(sys.argv[1])):
		archive.addfile(tarfile.TarInfo(f"d/{i}"))
subprocess.run(["zstd", "-q", "-1", "-f", "-o", sys.argv[2]], input=buffer.getvalue(), check=True)
PY
}
many 99999 "$WORK/many.tar.zst"
good; cp "$WORK/many.tar.zst" "$REL/$P"; python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$REL/$P"
check "a package with exactly 100000 entries is accepted" "0" "$(rc_of attempt)"
many 100000 "$WORK/many.tar.zst"
good; cp "$WORK/many.tar.zst" "$REL/$P"; python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$REL/$P"
check "a package with 100001 entries is refused" "1" "$(rc_of attempt)"
python3 -I - "$WORK/bomb.tar.zst" <<'PY'
import subprocess, sys, tarfile, io
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
	info = tarfile.TarInfo(".PKGINFO")
	body = b"pkgname = acme\npkgver = 1.2.3-1\narch = x86_64\npackager = Glyndor <noreply@glyndor.net>\n"
	info.size = len(body)
	archive.addfile(info, io.BytesIO(body))
	big = tarfile.TarInfo("usr/share/acme/zeros")
	big.size = 2 * 1024 ** 3 + 4096
	archive.addfile(big, Zeros(big.size))
proc.stdin.close()
proc.wait()
PY
good; cp "$WORK/bomb.tar.zst" "$REL/$P"; python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$REL/$P"
check "a package that unpacks to more than 2 GiB is refused" "1" "$(rc_of attempt)"
check "and says so, having read no more than the cap" "1" "$(says 'unpacks to more than')"
rm -f "$WORK/bomb.tar.zst" "$WORK/many.tar.zst"

for format in gzip xz; do
	good; python3 -I "$FIXTURES/mkpkg.py" "$WORK/plain.tar.zst" acme 1.2.3-1 x86_64; zstd -dc -q "$WORK/plain.tar.zst" | "$format" -c > "$REL/$P"
	python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$REL/$P"
	check "a signed package compressed with $format is refused before a decompressor sees it" "1" "$(rc_of attempt)"
	check "and says that it lacks the zstd magic" "1" "$(says 'zstd magic')"
done

echo "-- what was downloaded is not what the listing said"
good; AFTER="ln -sf /etc/hostname $P.sig && rm $P.sig && ln -s /etc/hostname $P.sig"
check "a signature that is a symbolic link is refused" "1" "$(rc_of attempt)"
good; AFTER="rm $P && ln -s ../../etc/passwd $P"
check "a package that is a symbolic link is refused" "1" "$(rc_of attempt)"
good; AFTER="ln $P $WORK/extra-link"
check "a package with a second hard link is refused" "1" "$(rc_of attempt)"
good; AFTER="printf x > unlisted.txt"
check "a file that is not in the plan is refused" "1" "$(rc_of attempt)"
good; AFTER="rm $P.sig"
check "a signature that was not downloaded is refused" "1" "$(rc_of attempt)"
good; AFTER="printf x >> $P.sig"
check "a signature of another size than the listing's is refused" "1" "$(rc_of attempt)"
good; AFTER=""
check "a digest listed by GitHub that matches is accepted" "0" "$(FAKE_DIGEST=1 rc_of attempt)"
good; AFTER="python3 -I -c \"import sys; d=open('$P','rb').read(); open('$P','wb').write(bytes([d[0]^1])+d[1:])\""
check "a digest listed by GitHub that does not match is refused" "1" "$(FAKE_DIGEST=1 rc_of attempt)"
good; AFTER=""
check "a repository the products file does not know is a configuration error" "2" "$(REPO=nobody rc_of attempt)"
: > "$WORK/pre-existing.tsv"
rm -rf "$DL"; cp -a "$REL" "$DL"; listing "$REL" > "$WORK/listing.json"
rc=0
python3 -I "$ADMIT" check --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/listing.json" --dir "$DL" \
	--ed25519-keys "$KEYS/release.b64" --out "$WORK/pre-existing.tsv" > /dev/null 2>&1 || rc=$?
check "a manifest that already exists is not overwritten" "2" "$rc"
check "and is left as it was" "0" "$(stat -c%s "$WORK/pre-existing.tsv")"

finish
