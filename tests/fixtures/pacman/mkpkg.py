#!/usr/bin/env python3
"""Build a tiny .pkg.tar.zst for the tests, with the fields and the members the case needs.

  mkpkg.py OUT NAME PKGVER ARCH [--set key=value]... [--append key=value]... [--drop key]...
           [--member path=content]... [--symlink path=target]... [--hardlink path=target]...
           [--device path]... [--raw-member path]... [--no-pkginfo] [--second-pkginfo] [--makepkg-layout] [--late-pkginfo]

PKGVER is the whole pkgver, revision included (1.2.3-1). The defaults are what the
channel admits; every option breaks one thing on purpose.
"""
import argparse
import gzip
import io
import subprocess
import sys
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("out")
parser.add_argument("name")
parser.add_argument("pkgver")
parser.add_argument("arch")
parser.add_argument("--set", action="append", default=[])
parser.add_argument("--drop", action="append", default=[])
parser.add_argument("--append", action="append", default=[])
parser.add_argument("--member", action="append", default=[])
parser.add_argument("--symlink", action="append", default=[])
parser.add_argument("--hardlink", action="append", default=[])
parser.add_argument("--device", action="append", default=[])
parser.add_argument("--raw-member", action="append", default=[])
parser.add_argument("--no-pkginfo", action="store_true")
parser.add_argument("--makepkg-layout", action="store_true")
parser.add_argument("--late-pkginfo", action="store_true")
parser.add_argument("--escapes", action="store_true", help="read \\x00 style escapes in --set and --append values")
parser.add_argument("--no-end-mark", action="store_true", help="cut the zero blocks that close the archive")
parser.add_argument("--zero-trailer", type=int, default=0, help="this many zero bytes after the archive")
parser.add_argument("--junk-trailer", type=int, default=0, help="this many non-zero bytes after the archive")
parser.add_argument("--tar-trailer", action="store_true", help="a second complete tar archive after the first")
parser.add_argument("--huge-header", metavar="TYPE", help="a header of this type (x, g, L, K) that claims two gigabytes of extension and has none")
parser.add_argument("--global-pax", action="store_true", help="a global pax header at the start")
parser.add_argument("--typeflag", action="append", default=[], help="TYPE=name: a member with that raw type flag, no data")
parser.add_argument("--dir-pax-size", action="append", default=[], help="name=N: a folder whose pax header says it has N bytes")
parser.add_argument("--second-pkginfo", action="store_true")
parser.add_argument("--mode", action="append", default=[], help="path=OCTAL: the mode of that member (default 644)")
parser.add_argument("--bad-mtree", help="what .MTREE holds instead of the listing of the members: junk, extra (a path that is not in the archive), missing (one left out), absolute, dotdot, twomembers, trailing, cut, continued, command, duplicate")
parser.add_argument("--xattr", action="append", default=[], help="path=KEY=VALUE: a pax header KEY with VALUE on that member (SCHILY.xattr.security.capability, for one)")
args = parser.parse_args()

fields = [
	("pkgname", args.name),
	("pkgver", args.pkgver),
	("pkgdesc", "A package built by a test"),
	("url", "https://glyndor.net"),
	("builddate", "1700000000"),
	("packager", "Glyndor <noreply@glyndor.net>"),
	("size", "4"),
	("arch", args.arch),
	("license", "MIT"),
]
fields = [(k, v) for k, v in fields if k not in args.drop]
for item in args.set:
	key, _, value = item.partition("=")
	if key in {"pkgname", "pkgver", "arch", "packager", "pkgbase", "size", "builddate"} and key not in args.drop:
		fields = [(k, v) for k, v in fields if k != key]
	fields.append((key, value))
for item in args.append:
	key, _, value = item.partition("=")
	fields.append((key, value))
if args.escapes:
	fields = [(k, v.encode().decode("unicode_escape")) for k, v in fields]
text = "".join(f"{k} = {v}\n" for k, v in fields)


pax = {}
for item in args.xattr:
	path, _, rest = item.partition("=")
	key, _, value = rest.partition("=")
	pax.setdefault(path, {})[key] = value
modes = {item.partition("=")[0]: int(item.partition("=")[2], 8) for item in args.mode}
written = []


def escape(name):
	"""A name as mtree writes it: anything that is not plain is a backslash and three octal digits."""
	return "".join(c if c.isalnum() and c.isascii() or c in "._/+@-" else "\\%03o" % ord(c) for c in name)


def mtree_of(names):
	"""An .MTREE as makepkg writes it: gzip of mtree text listing every member but itself, `./` first."""
	names = [n for n in names if n != ".MTREE"]
	if args.bad_mtree == "extra":
		names.append("usr/not/in/the/archive")
	elif args.bad_mtree == "missing" and names:
		names.pop()
	elif args.bad_mtree == "absolute":
		names.append("/etc/pacman.conf")
	elif args.bad_mtree == "dotdot":
		names.append("../x")
	if args.bad_mtree == "junk":
		return b"#mtree\nnot gzip\n"
	if args.bad_mtree == "duplicate":
		names.append(names[0])
	text = "#mtree\n/set type=file uid=0 gid=0 mode=644\n" + "".join(f"./{escape(n)} time=0.0 size=1\n" for n in names)
	if args.bad_mtree == "continued":
		text += "./usr/x time=0.0 \\\nsize=1\n"
	if args.bad_mtree == "command":
		text += "/unknown foo\n"

	def gz(content):
		data = io.BytesIO()
		with gzip.GzipFile(fileobj=data, mode="wb", mtime=0) as z:
			z.write(content.encode())
		return data.getvalue()

	if args.bad_mtree == "twomembers":
		return gz(text) + gz("./etc/evil time=0.0\n")
	if args.bad_mtree == "trailing":
		return gz(text) + b"garbage"
	if args.bad_mtree == "cut":
		return gz(text)[:-8]
	return gz(text)


def add(archive, name, data=b"", kind=tarfile.REGTYPE, link=""):
	info = tarfile.TarInfo(name)
	info.mtime, info.uid, info.gid, info.uname, info.gname, info.mode = 0, 0, 0, "root", "root", modes.get(name, 0o644)
	written.append(name)
	info.pax_headers = dict(pax.get(name, {}))
	info.type, info.linkname = kind, link
	info.size = len(data) if kind == tarfile.REGTYPE else 0
	archive.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)


def body(buffer, mtree):
	with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT, pax_headers={"comment": "global"} if args.global_pax else None) as archive:
		if args.makepkg_layout:
			# the order makepkg 7.1.0 writes: .BUILDINFO, .MTREE, .PKGINFO, then the files
			add(archive, ".BUILDINFO", b"format = 2\n")
			add(archive, ".MTREE", mtree)
		if args.late_pkginfo:
			add(archive, f"usr/share/{args.name}/first", b"x")
		if not args.no_pkginfo:
			add(archive, ".PKGINFO", text.encode())
		if args.second_pkginfo:
			add(archive, ".PKGINFO", text.encode())
		# entries whose name starts with a dot come first, as in a package from makepkg
		for item in args.member:
			path, _, content = item.partition("=")
			if path.startswith("."):
				add(archive, path, open(content[1:], "rb").read() if content.startswith("@") else content.encode())
		for item in args.symlink:
			path, _, target = item.partition("=")
			if path.startswith("."):
				add(archive, path, kind=tarfile.SYMTYPE, link=target)
		add(archive, f"usr/share/{args.name}/README", b"test\n")
		for item in args.member:
			if item.startswith("."):
				continue
			path, _, content = item.partition("=")
			add(archive, path, content.encode())
		for item in args.raw_member:
			add(archive, item, b"x")
		for item in args.symlink:
			path, _, target = item.partition("=")
			if not path.startswith("."):
				add(archive, path, kind=tarfile.SYMTYPE, link=target)
		for item in args.hardlink:
			path, _, target = item.partition("=")
			add(archive, path, kind=tarfile.LNKTYPE, link=target)
		if args.huge_header:
			info = tarfile.TarInfo("PaxHeaders/x")
			info.type, info.size = args.huge_header.encode(), 2 * 1024**3
			archive.fileobj.write(info.tobuf(tarfile.GNU_FORMAT, "utf-8", "surrogateescape"))
		for item in args.typeflag:
			flag, _, path = item.partition("=")
			add(archive, path, kind=flag.encode())
		for item in args.dir_pax_size:
			path, _, size = item.partition("=")
			info = tarfile.TarInfo(path)
			info.type, info.mode = tarfile.DIRTYPE, 0o755
			info.pax_headers = {"size": size}
			archive.addfile(info)
		for item in args.device:
			add(archive, item, kind=tarfile.CHRTYPE)


# The listing in .MTREE has to name the members that are written, so the archive is written once to find them out and again with the listing.
written.clear()
body(io.BytesIO(), b"")
names = list(written)
written.clear()
buffer = io.BytesIO()
body(buffer, mtree_of(names))
data = buffer.getvalue()
if args.no_end_mark:
	data = data.rstrip(b"\0")
	data += b"\0" * (-len(data) % 512)
data += b"\0" * args.zero_trailer + b"X" * args.junk_trailer
if args.tar_trailer:
	second = io.BytesIO()
	with tarfile.open(fileobj=second, mode="w") as extra:
		add(extra, ".PKGINFO", b"pkgname = evil\n")
	data += second.getvalue()
done = subprocess.run(["zstd", "-q", "-19", "-f", "-o", args.out], input=data)
sys.exit(done.returncode)
