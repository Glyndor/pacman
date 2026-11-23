#!/usr/bin/env bash
#
# pkgpolicy.py through package-reader.py: what a package may install is a list per package, default deny. A package signed with
# the release key could still carry a pacman.conf with `SigLevel = Never`, a keyring of its own, a hook, a unit of another name, a
# setuid binary, a link that points at /etc/shadow or an .MTREE that says something else than the archive; each of those is
# built here and refused, and the ordinary package is read. The files of pacman, of sudo and of the login are refused even when a
# line of package-paths.txt names them (and that file then does not load).
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
printf 'acme\tusr/bin/acme usr/lib/acme/ usr/share/acme/ etc/acme.conf usr/lib/systemd/system/acme*.service >usr/bin/other\n' > "$WORK/paths.txt"
pkg() { python3 -I "$FIXTURES/mkpkg.py" "$WORK/p.pkg.tar.zst" acme 1.2.3-1 x86_64 "$@"; }
read_it() { python3 -I "$READER" --paths "${PATHSFILE:-$WORK/paths.txt}" --scriptlets "${SCRIPTLETS:-$FIXTURES/scriptlets-none.txt}" --package "${NAME:-acme}" "$WORK/p.pkg.tar.zst"; }
refused() { # <label> <expected text> <mkpkg options...>
	local label="$1" text="$2"
	shift 2
	pkg "$@"
	check "$label" "1" "$(rc_of read_it)"
	check "and says why" "1" "$(says "$text")"
}

pkg --makepkg-layout --member usr/bin/acme=x --member usr/lib/acme/helper=x --member etc/acme.conf=x --member usr/lib/systemd/system/acme.service=x \
	--symlink usr/lib/acme/link=/usr/lib/acme/helper --symlink usr/lib/acme/alias=../acme/helper --symlink usr/lib/acme/other=/usr/bin/other \
	--hardlink usr/lib/acme/hard=usr/lib/acme/helper
check "an ordinary package in its own places, with links among them, is read" "0" "$(rc_of read_it)"

echo "-- places a package may not install (default deny)"
refused "a pacman.conf with SigLevel = Never" "etc/pacman.conf" --member etc/pacman.conf='SigLevel = Never'
refused "a mirror list of pacman" "etc/pacman.d/mirrorlist.glyndor" --member etc/pacman.d/mirrorlist.glyndor='Server = http://evil'
refused "a keyring of pacman with a key of its own" "usr/share/pacman/keyrings/evil.gpg" --member usr/share/pacman/keyrings/evil.gpg=x
refused "a hook of libalpm, which runs as root at every transaction" "usr/share/libalpm/hooks/evil.hook" --member usr/share/libalpm/hooks/evil.hook=x
refused "a systemd unit under another name" "usr/lib/systemd/system/other.service" --member usr/lib/systemd/system/other.service=x
refused "a tmpfiles.d entry" "usr/lib/tmpfiles.d/evil.conf" --member usr/lib/tmpfiles.d/evil.conf=x
refused "a sysusers.d entry" "usr/lib/sysusers.d/evil.conf" --member usr/lib/sysusers.d/evil.conf=x
refused "a udev rule" "usr/lib/udev/rules.d/evil.rules" --member usr/lib/udev/rules.d/evil.rules=x
refused "a cron job" "etc/cron.d/evil" --member etc/cron.d/evil=x
refused "a sudoers entry" "etc/sudoers.d/evil" --member etc/sudoers.d/evil=x
refused "a file in the folder of another binary" "usr/bin/sh" --member usr/bin/sh=x
refused "a file where no pattern of the line reaches" "opt/acme/x" --member opt/acme/x=x
refused "a folder that no pattern reaches" "srv" --raw-member srv/x
check "a package that has no line in the file installs nothing" "1" "$(NAME=nobody rc_of read_it)"
check "and says that there is no line" "1" "$(says 'has no line for nobody')"

echo "-- bits of privilege"
refused "a setuid binary" "setuid or setgid" --member usr/bin/acme=x --mode usr/bin/acme=4755
refused "a setgid binary" "setuid or setgid" --member usr/bin/acme=x --mode usr/bin/acme=2755
refused "a setuid and setgid binary" "setuid or setgid" --member usr/bin/acme=x --mode usr/bin/acme=6755
refused "a setuid file that is not executable" "setuid or setgid" --member usr/lib/acme/x=x --mode usr/lib/acme/x=4644
pkg --member usr/bin/acme=x --mode usr/bin/acme=0755
check "an ordinary executable is read" "0" "$(rc_of read_it)"
pkg --member usr/lib/acme/x=x --mode usr/lib/acme/x=1755
check "the sticky bit alone is not a bit of privilege" "0" "$(rc_of read_it)"

echo "-- where a link may point"
refused "a symbolic link to /etc/shadow" "links to '/etc/shadow'" --symlink usr/bin/acme=/etc/shadow
refused "a symbolic link that climbs out of the tree" "outside the package" --symlink usr/bin/acme=../../../../etc/shadow
refused "a symbolic link to the root" "links to '/'" --symlink usr/bin/acme=/
refused "a symbolic link to a folder of pacman" "links to" --symlink usr/lib/acme/l=/etc/pacman.d
refused "a symbolic link to a place of the system" "links to" --symlink usr/lib/acme/l=/usr/bin/sh
refused "a relative symbolic link that lands outside what the package may install" "links to" --symlink usr/lib/acme/l=../../bin/sh
refused "a hard link to a file of the system" "links to" --hardlink usr/lib/acme/h=usr/bin/sh
refused "a hard link to a place of pacman" "links to" --hardlink usr/lib/acme/h=etc/pacman.conf
refused "a hard link that climbs out" "hard link out of its tree" --hardlink usr/lib/acme/h=../x
pkg --symlink usr/lib/acme/l=/usr/lib/acme
check "a symbolic link to a folder of the package is read" "0" "$(rc_of read_it)"

echo "-- the .MTREE"
pkg --makepkg-layout
check "an .MTREE that lists the members of the archive is read" "0" "$(rc_of read_it)"
refused "an .MTREE that lists a path that is not in the archive" "do not list the same paths" --makepkg-layout --bad-mtree extra
refused "an .MTREE that leaves a member out" "do not list the same paths" --makepkg-layout --bad-mtree missing
refused "an .MTREE that is not gzip" "not gzip" --makepkg-layout --bad-mtree junk
refused "an .MTREE with an absolute path" "not a path inside the package" --makepkg-layout --bad-mtree absolute
refused "an .MTREE with .." "not a path inside the package" --makepkg-layout --bad-mtree dotdot
refused "two .MTREE members" "two .MTREE" --makepkg-layout --raw-member .MTREE
python3 -I - "$WORK/mtree-bomb" <<'PY'
import gzip, sys
with gzip.open(sys.argv[1], "wb") as z:
	z.write(b"#mtree\n" + b"./usr/x time=0\n" * (3 * 1024 * 1024))
PY
pkg --member ".MTREE=@$WORK/mtree-bomb"
check "an .MTREE that unpacks to more than 8 MiB" "1" "$(rc_of read_it)"
check "and says so" "1" "$(says 'more than 8388608 bytes')"

echo "-- links are read strictly, because the kernel follows them one component at a time"
refused "a member inside a link of the same package" "is a link of the same package" --symlink usr/lib/acme/d=/usr/lib/acme --member usr/lib/acme/d/f=x
refused "a target with .. after a name" "links to" --symlink usr/lib/acme/a=../acme/../../bin/sh
refused "an absolute target with a dot component" "links to" --symlink usr/lib/acme/a=/usr/lib/acme/./x
refused "an absolute target with .. in it, even where it would stay inside" "links to" --symlink usr/lib/acme/a=/usr/lib/acme/../acme/x
refused "a relative target that goes through a link of the package" "through usr/lib/acme/d" --symlink usr/lib/acme/d=/usr/lib/acme --symlink usr/lib/acme/e=d/f
refused "the same member twice" "is in the package twice" --member usr/lib/acme/x=1 --raw-member usr/lib/acme/x
refused "a loop of links" "more than 8 links" --symlink usr/lib/acme/a=/usr/lib/acme/b --symlink usr/lib/acme/b=/usr/lib/acme/a
pkg --member usr/lib/acme/real=x --symlink usr/lib/acme/a=/usr/lib/acme/b --symlink usr/lib/acme/b=/usr/lib/acme/c --symlink usr/lib/acme/c=/usr/lib/acme/real
check "a chain of three links that ends at a file of the package is read" "0" "$(rc_of read_it)"
pkg --symlink usr/lib/acme/a=../acme/real --member usr/lib/acme/real=x
check "a relative target with the .. first is read" "0" "$(rc_of read_it)"

echo "-- extended attributes and capabilities travel in pax headers, and are not admitted"
for key in SCHILY.xattr.security.capability LIBARCHIVE.xattr.security.capability RHT.security.selinux SCHILY.acl.access SCHILY.xattr.user.x; do
	refused "a member with $key" "extended attribute or header this channel does not admit" --member usr/bin/acme=x --xattr "usr/bin/acme=$key=AAAA"
done
pkg --member "usr/lib/acme/$(printf 'd%.0s' $(seq 1 130))=x"
check "a member with a name so long that its pax header carries the path is read" "0" "$(rc_of read_it)"
check "the host's reader finds the extended attribute by itself, writing the archive out again, and refuses" "1" "$(pkg --member usr/bin/acme=x --xattr "usr/bin/acme=SCHILY.xattr.security.capability=AAAA"; python3 -I - "$READER" "$WORK/p.pkg.tar.zst" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("package_reader", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
	module.read_with_bsdtar(sys.argv[2])
except module.Refused as exc:
	print(1 if "extended attributes, ACLs or security labels" in str(exc) else 0)
else:
	print(0)
PY
)"

echo "-- the .MTREE is exactly one gzip member, of lines this channel understands"
refused "an .MTREE with a second gzip member after the first" "exactly one complete gzip member" --makepkg-layout --bad-mtree twomembers
refused "an .MTREE with bytes after the gzip data" "exactly one complete gzip member" --makepkg-layout --bad-mtree trailing
refused "an .MTREE that is cut" "exactly one complete gzip member" --makepkg-layout --bad-mtree cut
refused "an .MTREE with a line that continues on the next one" "continues on the next" --makepkg-layout --bad-mtree continued
refused "an .MTREE with a command that is not /set or /unset" "neither /set nor /unset" --makepkg-layout --bad-mtree command
refused "an .MTREE that lists a path twice" "twice" --makepkg-layout --bad-mtree duplicate
pkg --makepkg-layout
check "the host's reader lists the same paths in the .MTREE as this reader" "0" "$(python3 -I - "$READER" "$WORK/p.pkg.tar.zst" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("package_reader", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
_, _, theirs, _ = module.read_with_bsdtar(sys.argv[2])
_, _, ours, _ = module.read_with_tarfile(sys.argv[2])
print(0 if theirs == ours and ours else 1)
PY
)"

echo "-- the .INSTALL is code that pacman runs as root, and only the one whose hash is listed for the package is carried"
INSTALL_TEXT='post_install() { echo hello; }'
INSTALL_SHA="$(printf '%s' "$INSTALL_TEXT" | sha256sum | cut -d' ' -f1)"
printf 'acme\t%s\tthe test package says hello once\n' "$INSTALL_SHA" > "$WORK/scriptlets.txt"
printf 'other\t%s\tsome other package\n' "$INSTALL_SHA" > "$WORK/scriptlets-other.txt"
pkg --member ".INSTALL=$INSTALL_TEXT"
check "a package with no line in the list of scriptlets cannot carry an .INSTALL" "1" "$(rc_of read_it)"
check "and the refusal prints the hash it saw, to be reviewed and added" "1" "$(says "$INSTALL_SHA")"
check "and says that pacman runs it as root" "1" "$(says 'pacman runs it as root')"
check "the list of another package does not allow it" "1" "$(SCRIPTLETS="$WORK/scriptlets-other.txt" rc_of read_it)"
check "the .INSTALL whose hash is listed for the package is carried" "0" "$(SCRIPTLETS="$WORK/scriptlets.txt" rc_of read_it)"
pkg --member ".INSTALL=${INSTALL_TEXT}x"
check "an .INSTALL with a byte more is not the one listed" "1" "$(SCRIPTLETS="$WORK/scriptlets.txt" rc_of read_it)"
pkg --member ".INSTALL=post_install() { echo hellp; }"
check "an .INSTALL with a byte changed is not the one listed" "1" "$(SCRIPTLETS="$WORK/scriptlets.txt" rc_of read_it)"
check "and the hash of the changed one is printed" "1" "$(says "$(printf '%s' 'post_install() { echo hellp; }' | sha256sum | cut -d' ' -f1)")"
refused "two .INSTALL in the archive" "twice" --member ".INSTALL=$INSTALL_TEXT" --raw-member .INSTALL
pkg --symlink .INSTALL=/etc/passwd
check "an .INSTALL that is a link" "1" "$(SCRIPTLETS="$WORK/scriptlets.txt" rc_of read_it)"
check "and says it is not a regular file" "1" "$(says 'not a regular file')"
head -c 300000 /dev/zero | tr '\0' 'a' > "$WORK/big-install"
pkg --member ".INSTALL=@$WORK/big-install"
check "an .INSTALL of more than 256 KiB" "1" "$(SCRIPTLETS="$WORK/scriptlets.txt" rc_of read_it)"
refused "an entry .HOOK that nobody listed" "entry with a dot at the root" --member .HOOK=x
refused "an entry .SIGN that nobody listed" "entry with a dot at the root" --member .SIGN=x
refused "a folder with a dot at the root" "entry with a dot at the root" --raw-member .hidden/x
refused "a hook of libalpm in its own folder" "usr/share/libalpm/hooks/evil.hook" --member usr/share/libalpm/hooks/evil.hook=x
refused "a hook of the administrator" "etc/pacman.d/hooks/evil.hook" --member etc/pacman.d/hooks/evil.hook=x
refused "a .BUILDINFO that is a link" "not a regular file" --symlink .BUILDINFO=/etc/passwd
refused "a .CHANGELOG that is a link" "not a regular file" --symlink .CHANGELOG=/etc/passwd
head -c 1100000 /dev/zero | tr '\0' 'a' > "$WORK/big-buildinfo"
refused "a .BUILDINFO of more than a megabyte" "larger than" --member ".BUILDINFO=@$WORK/big-buildinfo"
pkg --member ".BUILDINFO=format = 2" --member ".CHANGELOG=a line"
check "a .BUILDINFO and a .CHANGELOG that are regular files and small are carried" "0" "$(rc_of read_it)"
check "the host's reader reads the same .INSTALL as this reader" "0" "$(pkg --member ".INSTALL=$INSTALL_TEXT"; python3 -I - "$READER" "$WORK/p.pkg.tar.zst" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("package_reader", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
_, _, _, theirs = module.read_with_bsdtar(sys.argv[2])
_, _, _, ours = module.read_with_tarfile(sys.argv[2])
print(0 if theirs == ours and ours == b"post_install() { echo hello; }" else 1)
PY
)"
printf 'acme\tnot-a-hash\twhy\n' > "$WORK/bad-s1.txt"
check "a list of scriptlets with a line that has no hash does not load" "2" "$(SCRIPTLETS="$WORK/bad-s1.txt" rc_of read_it)"
printf 'acme\t%s\n' "$INSTALL_SHA" > "$WORK/bad-s2.txt"
check "a line with no reason does not load" "2" "$(SCRIPTLETS="$WORK/bad-s2.txt" rc_of read_it)"
printf 'acme\t%s\twhy\nacme\t%s\twhy again\n' "$INSTALL_SHA" "$INSTALL_SHA" > "$WORK/bad-s3.txt"
check "the same hash twice for a package does not load" "2" "$(SCRIPTLETS="$WORK/bad-s3.txt" rc_of read_it)"
check "a list that is not there does not load" "2" "$(SCRIPTLETS="$WORK/none-s.txt" rc_of read_it)"
check "the list of the repository loads, and is empty today" "0" "$(python3 -I - "$HERE/scripts/admit/pkgpolicy.py" "$HERE/scripts/admit/package-scriptlets.txt" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pkgpolicy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.exit(0 if module.load_scriptlets(sys.argv[2]) == {} else 1)
PY
echo $?)"

echo "-- the file of paths"
printf 'acme\tetc/pacman.conf\n' > "$WORK/bad1.txt"
check "a line that names pacman.conf does not load" "2" "$(PATHSFILE="$WORK/bad1.txt" rc_of read_it)"
check "and says that no product package may install there" "1" "$(says 'no product package may install')"
printf 'acme\tusr/share/pacman/keyrings/\n' > "$WORK/bad2.txt"
check "a line that names the keyrings of pacman does not load" "2" "$(PATHSFILE="$WORK/bad2.txt" rc_of read_it)"
printf 'acme\tusr/lib/systemd/system/*.service etc/pacman.d/*\n' > "$WORK/bad3.txt"
check "a pattern with a wildcard inside a forbidden folder does not load" "2" "$(PATHSFILE="$WORK/bad3.txt" rc_of read_it)"
printf 'acme\t../x\n' > "$WORK/bad4.txt"
check "a pattern with .. does not load" "2" "$(PATHSFILE="$WORK/bad4.txt" rc_of read_it)"
printf 'acme\t/usr/bin/acme\n' > "$WORK/bad5.txt"
check "a pattern with a leading slash does not load" "2" "$(PATHSFILE="$WORK/bad5.txt" rc_of read_it)"
printf 'acme\tusr/bin/acme\nacme\tusr/bin/other\n' > "$WORK/bad6.txt"
check "two lines for one package do not load" "2" "$(PATHSFILE="$WORK/bad6.txt" rc_of read_it)"
printf 'acme usr/bin/acme\n' > "$WORK/bad7.txt"
check "a line with no TAB does not load" "2" "$(PATHSFILE="$WORK/bad7.txt" rc_of read_it)"
check "a file that is not there does not load" "2" "$(PATHSFILE="$WORK/none.txt" rc_of read_it)"
check "the file of the repository loads" "0" "$(python3 -I - "$HERE/scripts/admit/pkgpolicy.py" "$HERE/scripts/admit/package-paths.txt" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pkgpolicy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
rules = module.load(sys.argv[2])
sys.exit(0 if {"podman", "podman-docker", "podup", "epistle", "helmly-agent", "helmly", "epistle-panel"} <= set(rules) else 1)
PY
echo $?)"
check "and no pattern of the repository lets a link or a file into the forbidden places" "0" "$(python3 -I - "$HERE/scripts/admit/pkgpolicy.py" "$HERE/scripts/admit/package-paths.txt" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pkgpolicy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
bad = 0
for package, patterns in module.load(sys.argv[2]).items():
	for pattern in patterns:
		probe = pattern.lstrip(">").replace("*", "x").rstrip("/")
		if module.forbidden(probe):
			bad += 1
print(bad)
PY
)"

finish
