#!/usr/bin/env bash
#
# List a package and read its .PKGINFO with the reader that opens it on the host: the bsdtar (libarchive) of the
# Arch image, the one pacman uses. Runs INSIDE that image, through run-in-arch.sh, with no network.
#
#   list-package.sh <package in /work> <folder in /work>
#
# Writes <folder>/list.txt (bsdtar -tv, one line per member), <folder>/pkginfo (the bytes of .PKGINFO, at most 64 KiB
# and one more byte so that a larger one is seen as larger), <folder>/version and, when the package has an .MTREE,
# <folder>/install (the bytes of .INSTALL, at most 256 KiB and one more byte, when the package has one), <folder>/mtree.list: what libarchive reads in it, one path per line (the format of an .MTREE is one it understands), and
# <folder>/pax.keys: the keys of extended attributes, ACLs and security labels that libarchive reads in the headers of the members,
# found by writing the archive out again in the pax format (the listing of bsdtar does not show them). Exits non-zero when bsdtar fails
# for any reason: a package it cannot read is refused, not read some other way.
set -euo pipefail
export LC_ALL=C

pkg="${1:?usage: list-package.sh <package> <folder>}"
out="${2:?usage: list-package.sh <package> <folder>}"
bsdtar --version > "$out/version"
list_cap=$((64 * 1024 * 1024))
# `head` closes the pipe once the listing is longer than the cap, which makes bsdtar stop; the size says it happened.
timeout 300 bsdtar -tvf "$pkg" 2> "$out/list.err" | head -c "$((list_cap + 1))" > "$out/list.txt"
if [ "$(stat -c%s "$out/list.txt")" -gt "$list_cap" ]; then
	echo "the listing of the package is longer than $list_cap bytes" >&2
	exit 3
fi
timeout 120 bsdtar -xOf "$pkg" .PKGINFO 2>> "$out/list.err" | head -c 65537 > "$out/pkginfo"
if grep -q -E ' (\./)?\.MTREE$' "$out/list.txt"; then
	timeout 120 bsdtar -xOf "$pkg" .MTREE 2>> "$out/list.err" | head -c 8388609 > "$out/mtree.raw"
	timeout 120 bsdtar -tf "$out/mtree.raw" 2>> "$out/list.err" | head -c 67108865 > "$out/mtree.list"
	rm -f "$out/mtree.raw"
fi
# The extended attributes of a member (a file capability, an ACL, a security label) do not show in a listing. libarchive reads
# them, so what it writes out again carries them; any such record is named here, and an empty file is the answer that there are none.
set +e
timeout 900 bsdtar -cf - --format=pax @"$pkg" 2>> "$out/list.err" | grep -a -o -E '[0-9]+ (SCHILY|LIBARCHIVE|RHT|GNU|APPLE)\.[A-Za-z0-9_.-]+=' | sort -u > "$out/pax.keys"
codes=("${PIPESTATUS[@]}")
set -e
if [ "${codes[0]}" -ne 0 ] || [ "${codes[1]}" -gt 1 ] || [ "${codes[2]}" -ne 0 ]; then
	echo "bsdtar could not write the package out again to look for extended attributes" >&2
	exit 4
fi
if grep -q -E ' (\./)?\.INSTALL$' "$out/list.txt"; then
	timeout 120 bsdtar -xOf "$pkg" .INSTALL 2>> "$out/list.err" | head -c 262145 > "$out/install"
fi
