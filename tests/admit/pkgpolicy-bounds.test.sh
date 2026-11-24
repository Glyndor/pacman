#!/usr/bin/env bash
#
# pkgpolicy.py at its edges: the size of the entries with a dot, to the byte; a folder that no pattern reaches, as an entry of
# type folder and not only as the parent of a file; a file at the root of a folder it may fill but not be; the backup entries
# that are absolute or climb; a chain of links as long as it may be and one more; the line of the paths file that has two fields
# and a name that is not one. Each case is one that a mutation of the comparison (`>` for `>=`, `and` for `or`) would let through
# and the suites before it did not notice.
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
says() { if grep -q -F -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }
printf 'acme\tusr/bin/acme usr/lib/acme/ usr/share/acme/ etc/acme.conf >usr/bin/other\n' > "$WORK/paths.txt"
pkg() { python3 -I "$FIXTURES/mkpkg.py" "$WORK/p.pkg.tar.zst" acme 1.2.3-1 x86_64 "$@"; }
read_it() { python3 -I "$READER" --paths "${PATHSFILE:-$WORK/paths.txt}" --scriptlets "${SCRIPTLETS:-$FIXTURES/scriptlets-none.txt}" --package acme "$WORK/p.pkg.tar.zst"; }
bytes() { head -c "$1" /dev/zero | tr '\0' 'a' > "$2"; }

echo "-- the size of an entry with a dot is limited to the byte"
bytes 1048576 "$WORK/b1m"; bytes 1048577 "$WORK/b1m1"
pkg --member ".BUILDINFO=@$WORK/b1m"
check "a .BUILDINFO of exactly 1 MiB is carried" "0" "$(rc_of read_it)"
pkg --member ".BUILDINFO=@$WORK/b1m1"
check "one of 1 MiB and a byte is refused" "1" "$(rc_of read_it)"
check "for its size" "1" "$(says 'larger than')"
bytes 262144 "$WORK/i256"; bytes 262145 "$WORK/i256p"
printf 'acme\t%s\ta script of exactly 256 KiB\n' "$(sha256sum "$WORK/i256" | cut -d' ' -f1)" > "$WORK/s1.txt"
pkg --member ".INSTALL=@$WORK/i256"
check "an .INSTALL of exactly 256 KiB whose hash is listed is carried" "0" "$(SCRIPTLETS="$WORK/s1.txt" rc_of read_it)"
# The readers refuse a script over 256 KiB themselves (one reads it and one does not), so the size rule of the policy is called alone:
size_unit() { # <size of the .INSTALL> <size of a .BUILDINFO>: the verdict of pkgpolicy.check on members of those sizes, "ok" or the refusal
	python3 -I - "$HERE/scripts/admit/pkgpolicy.py" "$1" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pkgpolicy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
rules = {"acme": ["usr/bin/acme"]}
listed = {"acme": {"a" * 64: "a test"}}
members = [("-", ".PKGINFO", 10, ""), ("-", ".INSTALL", int(sys.argv[2]), ""), ("-", ".BUILDINFO", int(sys.argv[3]), "")]
try:
	module.check("acme", rules, members, {}, "a" * 64, listed)
	print("ok")
except module.Refused as exc:
	print(str(exc))
PY
}
check "the policy carries an .INSTALL of exactly 256 KiB" "ok" "$(size_unit 262144 10)"
check "and refuses one of 256 KiB and a byte, listed or not, for its size" ".INSTALL is larger than a .INSTALL of a package may be" "$(size_unit 262145 10)"
check "and one of 300000 bytes, which the 1 MiB of the other entries would let through" ".INSTALL is larger than a .INSTALL of a package may be" "$(size_unit 300000 10)"
check "and carries a .BUILDINFO of exactly 1 MiB" "ok" "$(size_unit 10 1048576)"
check "and refuses one of 1 MiB and a byte" ".BUILDINFO is larger than a .BUILDINFO of a package may be" "$(size_unit 10 1048577)"

echo "-- what is never installed is refused by the policy even when a line of the paths file names it (a line that does, does not load)"
forbidden_unit() { # <pattern>: the verdict of pkgpolicy.check with a rule that names the pattern, as a line that skipped the loader would
	python3 -I - "$HERE/scripts/admit/pkgpolicy.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pkgpolicy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
	module.check("acme", {"acme": [sys.argv[2]]}, [("-", ".PKGINFO", 10, ""), ("-", sys.argv[2], 1, "")], {})
	print("ok")
except module.Refused as exc:
	print(str(exc).split(" (")[0])
PY
}
check "a rule that names etc/pacman.conf, had it got past the loader, would still not install it" "etc/pacman.conf is a place no product package may install" "$(forbidden_unit etc/pacman.conf)"
check "nor usr/share/libalpm/hooks/x" "usr/share/libalpm/hooks/x is a place no product package may install" "$(forbidden_unit usr/share/libalpm/hooks/x)"
check "while a rule for a place that is not forbidden installs it" "ok" "$(forbidden_unit usr/bin/acme)"

echo "-- a folder is judged as a folder"
for dir in usr usr/lib usr/lib/acme usr/lib/acme/sub/deeper usr/share/acme/docs etc usr/bin; do
	pkg --typeflag "5=$dir"
	check "a folder $dir, on the way to or inside what may be installed, is carried" "0" "$(rc_of read_it)"
done
for dir in srv opt usr/share/other usr/lib/other etc/other var/lib/acme home; do
	pkg --typeflag "5=$dir"
	check "a folder $dir that no pattern reaches is refused" "1" "$(rc_of read_it)"
	check "as a place the package may not install" "1" "$(says 'is not a place')"
done
pkg --raw-member usr/lib/acme
check "a file that is the root of a folder the package may fill, and not inside it, is refused" "1" "$(rc_of read_it)"
pkg --member usr/lib/acme/a=x
check "a file inside it is carried" "0" "$(rc_of read_it)"
pkg --raw-member usr/bin
check "a file where a folder of the way is, and no pattern names that file, is refused" "1" "$(rc_of read_it)"

echo "-- backup is a list of files of the package, as relative paths"
pkg --member etc/acme.conf=x --append backup=etc/acme.conf
check "a backup of a file the package installs is carried" "0" "$(rc_of read_it)"
pkg --member usr/lib/acme/f=x --append backup=/usr/lib/acme/f
check "an absolute backup, even at a place the package may fill, is refused" "1" "$(rc_of read_it)"
check "and says that it is not a file of the package" "1" "$(says 'not a file the package')"
pkg --member usr/lib/acme/f=x --append 'backup=usr/lib/acme/../../bin/sh'
check "a backup that climbs, though it starts inside a folder of the package, is refused" "1" "$(rc_of read_it)"
pkg --member usr/lib/acme/f=x --append backup=usr/bin/sh
check "a backup of a place the package may not install is refused" "1" "$(rc_of read_it)"

echo "-- a target with a dot first is read as it is"
pkg --member usr/lib/acme/real=x --symlink usr/lib/acme/l=./../acme/real
check "a relative target that starts with ./ and then goes up is carried when it lands in the package" "0" "$(rc_of read_it)"

echo "-- a chain of links, as long as it may be and one more"
chain() { # <number of links>: l1 -> l2 -> ... -> lN -> real
	local n="$1" i args=(--member usr/lib/acme/real=x)
	for i in $(seq 1 "$n"); do
		if [ "$i" -eq "$n" ]; then args+=(--symlink "usr/lib/acme/l$i=/usr/lib/acme/real"); else args+=(--symlink "usr/lib/acme/l$i=/usr/lib/acme/l$((i + 1))"); fi
	done
	pkg "${args[@]}"
}
chain 9
check "a chain of nine links that ends at a file of the package is carried" "0" "$(rc_of read_it)"
chain 10
check "one of ten is refused" "1" "$(rc_of read_it)"
check "for its length" "1" "$(says 'more than 8 links')"

echo "-- the paths file: two fields and a name that is not one"
printf 'A!\tusr/\n' > "$WORK/badname.txt"
check "a line with two fields whose first is not a package name does not load" "2" "$(PATHSFILE="$WORK/badname.txt" rc_of read_it)"
printf 'a\tusr/\n' > "$WORK/shortname.txt"
check "a name of one character is not a package name either" "2" "$(PATHSFILE="$WORK/shortname.txt" rc_of read_it)"
printf 'acme\tusr/ usr/\textra\n' > "$WORK/threefields.txt"
check "a line with three fields does not load" "2" "$(PATHSFILE="$WORK/threefields.txt" rc_of read_it)"

finish
