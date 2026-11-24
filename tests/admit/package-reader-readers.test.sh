#!/usr/bin/env bash
#
# Each reader of package-reader.py on its own. The two readers (tarfile and the bsdtar of the pinned image) have to agree and a package
# that either refuses is refused, so a test that goes through the whole reader cannot tell which of them did the refusing: a rule of
# one of them that stopped working would be covered by the other, and nobody would know. Here read_with_tarfile is called alone on
# packages made for it, and read_with_bsdtar alone with a stand-in for the container that writes the listing it is given, and each
# has to refuse by itself every case that the other would have caught too.
#
# Requires: python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
READER="$HERE/scripts/admit/package-reader.py"
mkdir -p "$WORK/m"
head -c 600000 /dev/zero | tr '\0' 'a' > "$WORK/a-line"
python3 -I - "$WORK/mtree-bomb" "$WORK/mtree-8m" "$WORK/mtree-ctl" <<'PY'
import gzip, sys
bomb, exact, control = sys.argv[1:4]
with gzip.open(bomb, "wb") as z:
	z.write(b"#mtree\n" + b"./usr/x time=0\n" * (3 * 1024 * 1024))
head = b"#mtree\n"
with gzip.open(exact, "wb") as z:
	z.write(head + b"#" * (8 * 1024 * 1024 - len(head) - 1) + b"\n")
with gzip.open(control, "wb") as z:
	z.write(b"#mtree\n\x01\n")
PY

python3 -I - "$READER" "$FIXTURES/mkpkg.py" "$WORK" > "$WORK/units.out" 2>&1 <<'PY' || true
import importlib.util
import io
import os
import subprocess
import sys
import tarfile

reader, mkpkg, work = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("package_reader", reader)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_run = subprocess.run


def package(*options):
	path = os.path.join(work, "u.pkg.tar.zst")
	subprocess.run([sys.executable, "-I", mkpkg, path, "acme", "1.2.3-1", "x86_64", *options], check=True)
	return path


def refuses(label, path, text, reader_function):
	try:
		reader_function(path)
	except module.Refused as exc:
		print(("ok    " if text in str(exc) else "FAIL  ") + label + ("" if text in str(exc) else f"\n        wanted {text!r}, got {exc}"))
	except Exception as exc:  # noqa: BLE001
		print(f"FAIL  {label}\n        a {type(exc).__name__}, not a refusal: {exc}")
	else:
		print(f"FAIL  {label}\n        the package was read")


def reads(label, path, reader_function):
	try:
		reader_function(path)
		print("ok    " + label)
	except Exception as exc:  # noqa: BLE001
		print(f"FAIL  {label}\n        {type(exc).__name__}: {exc}")


tar = module.read_with_tarfile
print("-- the reader of Python, alone")
refuses("an .MTREE that is not gzip", package("--makepkg-layout", "--bad-mtree", "junk"), "not gzip", tar)
refuses("an .MTREE of more than 8 MiB", package("--member", f".MTREE=@{work}/mtree-bomb"), "more than", tar)
reads("an .MTREE of exactly 8 MiB", package("--member", f".MTREE=@{work}/mtree-8m"), tar)
refuses("an .MTREE with a control character", package("--member", f".MTREE=@{work}/mtree-ctl"), "control character", tar)
refuses("an .MTREE with a line that continues", package("--makepkg-layout", "--bad-mtree", "continued"), "continues on the next", tar)
refuses("an .MTREE with a command that is not /set or /unset", package("--makepkg-layout", "--bad-mtree", "command"), "neither /set nor /unset", tar)
refuses("an .MTREE with an absolute path", package("--makepkg-layout", "--bad-mtree", "absolute"), "not a path inside", tar)
refuses("an .MTREE with .. in a path", package("--makepkg-layout", "--bad-mtree", "dotdot"), "not a path inside", tar)
refuses("an .MTREE that lists a path twice", package("--makepkg-layout", "--bad-mtree", "duplicate"), "twice", tar)
refuses("an .MTREE that is two gzip members", package("--makepkg-layout", "--bad-mtree", "twomembers"), "exactly one complete gzip member", tar)
refuses("a member with an extended attribute", package("--member", "usr/bin/acme=x", "--xattr", "usr/bin/acme=SCHILY.xattr.security.capability=AAAA"), "extended attribute", tar)
refuses("a setuid member", package("--member", "usr/bin/acme=x", "--mode", "usr/bin/acme=4755"), "setuid or setgid", tar)
refuses("a setgid member", package("--member", "usr/bin/acme=x", "--mode", "usr/bin/acme=2755"), "setuid or setgid", tar)
refuses("a hard link out of the tree", package("--hardlink", "usr/x=../../etc/passwd"), "hard link out of its tree", tar)
reads("an ordinary package", package("--makepkg-layout"), tar)


def late_pkginfo():
	buffer = io.BytesIO()
	with tarfile.open(fileobj=buffer, mode="w") as archive:
		for name, body in (("README", b"x"), (".PKGINFO", b"pkgname = acme\n")):
			info = tarfile.TarInfo(name)
			info.size = len(body)
			archive.addfile(info, io.BytesIO(body))
	path = os.path.join(work, "late.pkg.tar.zst")
	subprocess.run(["zstd", "-q", "-f", "-o", path], input=buffer.getvalue(), check=True)
	return path


refuses(".PKGINFO after an entry with no slash in its name", late_pkginfo(), "comes after the first ordinary entry", tar)

print("-- the reader of the host, alone, with the listing it is given")
LINE = "-rw-r--r--  0 root   root        5 Jan  1  1970 usr/share/acme/README\n"


def scenario(listing=LINE, pkginfo=b"pkgname = acme\n", pax="", mtree=None, rc=0, error="", boom=None):
	def fake(command, **kwargs):
		if command[0] == "rm":
			return real_run(command, **kwargs)
		if boom is not None:
			raise boom
		out = os.path.join(command[3], "out")
		for name, content in (("list.txt", listing.encode()), ("pkginfo", pkginfo), ("pax.keys", pax.encode())):
			with open(os.path.join(out, name), "wb") as f:
				f.write(content)
		if mtree is not None:
			with open(os.path.join(out, "mtree.list"), "wb") as f:
				f.write(mtree.encode())
		return subprocess.CompletedProcess(command, rc, "", error)

	return fake


dummy = package("--makepkg-layout")


def via(label, fake, text, config=False):
	module.subprocess.run = fake
	try:
		module.read_with_bsdtar(dummy)
		print(f"FAIL  {label}\n        read")
	except module.Refused as exc:
		print(("ok    " if text in str(exc) and not config else "FAIL  ") + label + ("" if text in str(exc) and not config else f"\n        wanted {text!r}, got {exc}"))
	except module.ConfigError as exc:
		print(("ok    " if config else "FAIL  ") + label + ("" if config else f"\n        a configuration error: {exc}"))
	finally:
		module.subprocess.run = real_run


via("a reader that takes too long", scenario(boom=subprocess.TimeoutExpired("x", 1)), "took too long")
via("a reader that cannot read the package", scenario(rc=1, error="boom"), "bsdtar could not read")
via("a reader that cannot run", scenario(rc=2, error="no engine"), "", config=True)
via("a listing that does not end with a line feed", scenario(listing=LINE.rstrip("\n")), "does not end with a line feed")
via("a listing line that cannot be read", scenario(listing="this is not a listing\n"), "cannot read")
via("extended attributes found by writing the archive out again", scenario(pax="47 LIBARCHIVE.xattr.security.capability=\n"), "extended attributes, ACLs or security labels")
via("a marker of an extended attribute in the listing", scenario(listing="-rw-r--r--@ 0 root   root        5 Jan  1  1970 usr/x\n"), "security label")
via("a setuid member", scenario(listing="-rwsr-xr-x  0 root   root        5 Jan  1  1970 usr/bin/x\n"), "setuid or setgid")
via("a setuid member with no execute bit", scenario(listing="-rwSr--r--  0 root   root        5 Jan  1  1970 usr/bin/x\n"), "setuid or setgid")
via("a setgid member", scenario(listing="-rwxr-sr-x  0 root   root        5 Jan  1  1970 usr/bin/x\n"), "setuid or setgid")
via("a setgid member with no execute bit", scenario(listing="-rwxr-Sr--  0 root   root        5 Jan  1  1970 usr/bin/x\n"), "setuid or setgid")
via("a listing of an .MTREE that does not end with a line feed", scenario(mtree="./usr/x"), "does not end with a line feed")
module.subprocess.run = scenario()
try:
	members, info, mtree, install = module.read_with_bsdtar(dummy)
	print("ok    an ordinary listing is read" if members == [("-", "usr/share/acme/README", 5, "")] else f"FAIL  an ordinary listing is read\n        {members}")
except Exception as exc:  # noqa: BLE001
	print(f"FAIL  an ordinary listing is read\n        {type(exc).__name__}: {exc}")
PY
cat "$WORK/units.out"
pass=$((pass + $(grep -c '^ok ' "$WORK/units.out" || true)))
fail=$((fail + $(grep -c '^FAIL ' "$WORK/units.out" || true)))
check "the harness itself ran to its end and printed cases" "yes" "$([ "$(grep -c -e '^ok ' -e '^FAIL ' "$WORK/units.out" || true)" -ge 29 ] && echo yes || echo no)"
check "and no traceback of its own is in its output" "0" "$(grep -c Traceback "$WORK/units.out" || true)"

finish
