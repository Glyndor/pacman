#!/usr/bin/env bash
#
# List a package and read its .PKGINFO with the reader that opens it on the host: the bsdtar (libarchive) of the
# Arch image, the one pacman uses. Runs INSIDE that image, through run-in-arch.sh, with no network.
#
#   list-package.sh <package in /work> <folder in /work>
#
# Writes <folder>/list.txt (bsdtar -tv, one line per member), <folder>/pkginfo (the bytes of .PKGINFO, at most 64 KiB
# and one more byte so that a larger one is seen as larger) and <folder>/version. Exits non-zero when bsdtar fails
# for any reason: a package it cannot read is refused, not read some other way.
set -euo pipefail
export LC_ALL=C

pkg="${1:?usage: list-package.sh <package> <folder>}"
out="${2:?usage: list-package.sh <package> <folder>}"
umask 000
bsdtar --version > "$out/version"
list_cap=$((64 * 1024 * 1024))
# `head` closes the pipe once the listing is longer than the cap, which makes bsdtar stop; the size says it happened.
timeout 300 bsdtar -tvf "$pkg" 2> "$out/list.err" | head -c "$((list_cap + 1))" > "$out/list.txt"
if [ "$(stat -c%s "$out/list.txt")" -gt "$list_cap" ]; then
	echo "the listing of the package is longer than $list_cap bytes" >&2
	exit 3
fi
timeout 120 bsdtar -xOf "$pkg" .PKGINFO 2>> "$out/list.err" | head -c 65537 > "$out/pkginfo"
