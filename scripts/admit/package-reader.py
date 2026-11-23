#!/usr/bin/env python3
"""Read a package the way its consumer will, and print its .PKGINFO as JSON.

  package-reader.py (--paths <file> --package <name> | --no-paths) <package.pkg.tar.zst>

The package is read twice, by two readers that must agree on everything: Python's tarfile (in a stream, with the bounds
on what an archive bomb can cost) and bsdtar, the libarchive pacman uses on the host, run in the pinned Arch image
(list-package.sh, through run-in-arch.sh). They have to give the same members (type, name, size, link target) and the
same bytes of .PKGINFO; any difference refuses the package, and tarfile decides nothing by itself. Only regular files,
folders and links are admitted; a member that is not a regular file and has a size, a global pax header, a sparse,
contiguous or unknown member, and anything after the end of the archive but zero blocks refuse it.

.PKGINFO is read strictly: no control byte, every line `key = value` or a comment, the file ends with a line feed, a
closed set of keys, and a name where a relation holds one.

What the package installs is judged too, by default deny (pkgpolicy.py and package-paths.txt, --paths and --package): every
member must be in a place its package may install, a link may only point at such a place, no member is setuid or setgid,
`backup` names files of the package, and `.MTREE`, when there is one, lists exactly the members of the archive. --no-paths
is for the one package this channel builds itself, whose members are compared with a fixed list elsewhere.

Exit 0 read (the fields on stdout), 1 refused, 2 no container engine for the reader of the host.
"""
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pkgpolicy  # noqa: E402

MAX_UNPACKED_BYTES = 2 * 1024 * 1024 * 1024
MAX_ENTRIES = 100000
MAX_PKGINFO_BYTES = 65536
MAX_MTREE_BYTES = 8 * 1024 * 1024
# The only keys of a pax header that a package of this channel may carry: what makepkg and libarchive write for names and times.
PAX_ALLOWED = {"path", "linkpath", "size", "mtime", "atime", "ctime", "uname", "gname"}
NAME_RE = re.compile(r"^[a-z0-9@_+][a-z0-9@._+-]+$")
SINGLE_KEYS = {"pkgname", "pkgbase", "pkgver", "pkgdesc", "url", "builddate", "packager", "size", "arch"}


class Refused(Exception):
	"""The package is not admitted."""


MAX_EXTENSION_BYTES = 1 << 20


class BoundedInfo(tarfile.TarInfo):
	"""A header whose extension (pax, GNU long name) is read only when it is small: tarfile reads that payload whole."""

	def _proc_pax(self, archive):
		if self.size > MAX_EXTENSION_BYTES:
			raise Refused(f"the package has an extended header of {self.size} bytes, over {MAX_EXTENSION_BYTES}")
		return super()._proc_pax(archive)

	def _proc_gnulong(self, archive):
		if self.size > MAX_EXTENSION_BYTES:
			raise Refused(f"the package has a long name header of {self.size} bytes, over {MAX_EXTENSION_BYTES}")
		return super()._proc_gnulong(archive)

	def _proc_sparse(self, archive):
		raise Refused("the package has a sparse member")


class ConfigError(Exception):
	"""The reader of the host cannot run."""


class Capped:
	"""A reader that stops the decompression of a bomb."""

	def __init__(self, stream, limit):
		self.stream, self.left = stream, limit
		self.pos, self.last_nonzero = 0, -1

	def read(self, size=-1):
		size = min(size if size and size > 0 else 1 << 20, self.left + 1)
		data = self.stream.read(size)
		self.left -= len(data)
		if self.left < 0:
			raise Refused(f"the package unpacks to more than {MAX_UNPACKED_BYTES} bytes")
		stripped = len(data.rstrip(b"\0"))
		if stripped:
			self.last_nonzero = self.pos + stripped - 1
		self.pos += len(data)
		return data


def read_mtree(raw):
	"""The paths an .MTREE lists, from its gzip text (what makepkg writes), bounded, and exactly one gzip member."""
	decoder = zlib.decompressobj(31)
	try:
		text = decoder.decompress(raw, MAX_MTREE_BYTES + 1)
	except zlib.error as exc:
		raise Refused(f".MTREE is not gzip data: {exc}")
	if len(text) > MAX_MTREE_BYTES or decoder.unconsumed_tail:
		raise Refused(f".MTREE unpacks to more than {MAX_MTREE_BYTES} bytes")
	if not decoder.eof or decoder.unused_data:
		raise Refused(".MTREE is not exactly one complete gzip member (it is cut, or something follows it that another reader would read)")
	if CONTROL_RE.search(text.decode("latin-1")):
		raise Refused(".MTREE holds a control character")
	paths = set()
	for line in text.decode("utf-8", "replace").split("\n"):
		if not line or line.startswith("#"):
			continue
		if line.endswith("\\"):
			raise Refused(".MTREE has a line that continues on the next one")
		if line.startswith("/"):
			if not (line.startswith("/set ") or line.startswith("/unset ") or line in ("/set", "/unset")):
				raise Refused(f".MTREE has a command that is neither /set nor /unset: {line[:40]!r}")
			continue
		path = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), line.split(" ", 1)[0])
		path = path[2:] if path.startswith("./") else path
		if not path or path.startswith("/") or ".." in path.split("/"):
			raise Refused(f".MTREE lists {path!r}, which is not a path inside the package")
		path = path.rstrip("/")
		if path in paths:
			raise Refused(f".MTREE lists {path!r} twice")
		paths.add(path)
	return paths


PKGINFO_KEYS = SINGLE_KEYS | {"license", "replaces", "group", "conflict", "provides", "backup", "depend", "optdepend",
	"makedepend", "checkdepend", "xdata"}
NAMED_KEYS = ("depend", "optdepend", "makedepend", "checkdepend", "provides", "conflict", "conflicts", "replaces")
PKGINFO_LINE_RE = re.compile(r"[a-z]+ = .*")
CONTROL_RE = re.compile(r"[\x00-\x09\x0b-\x1f\x7f]")


def relation_name(value, key):
	"""The package or soname a relation names, checked to be a name and nothing else."""
	target = value.split(": ", 1)[0] if key == "optdepend" else value
	target = re.split(r"[<>=]", target, maxsplit=1)[0]
	if not NAME_RE.fullmatch(target):
		raise Refused(f".PKGINFO {key} names {target!r}, which is not a package name")
	return target


def parse_pkginfo(text):
	"""Every line is `key = value` (or a comment), every key is one this channel knows, no control byte is in it."""
	if CONTROL_RE.search(text):
		raise Refused(".PKGINFO holds a control character (NUL, carriage return, tab, vertical tab, form feed...)")
	info = {}
	lines = text.split("\n")
	if lines[-1] != "":
		raise Refused(".PKGINFO does not end with a line feed")
	for number, line in enumerate(lines[:-1], 1):
		if line.startswith("#"):
			continue
		if not PKGINFO_LINE_RE.fullmatch(line):
			raise Refused(f".PKGINFO line {number} is not 'key = value'")
		key, _, value = line.partition(" = ")
		if key not in PKGINFO_KEYS and key != "conflicts":
			raise Refused(f".PKGINFO line {number} has a key this channel does not know: {key}")
		if key in SINGLE_KEYS and key in info:
			raise Refused(f".PKGINFO sets {key} twice")
		if key in NAMED_KEYS:
			relation_name(value, key)
		info.setdefault(key, []).append(value)
	return info


ZSTD_MAGIC = bytes.fromhex("28b52ffd")
KINDS = {tarfile.REGTYPE: "-", tarfile.AREGTYPE: "-", tarfile.DIRTYPE: "d", tarfile.SYMTYPE: "l", tarfile.LNKTYPE: "h"}
LIST_RE = re.compile(r"^([-dlhcbps?])([rwxsStT-]{9})([+@.]?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+[A-Z][a-z]{2}\s+\d+\s+(?:\d{4}|\d\d:\d\d)\s(.*)$")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def normal_name(name):
	name = name[2:] if name.startswith("./") else name
	return name.rstrip("/") if name != "/" else name


def unsafe_name(name):
	return not name or name.startswith("/") or "\0" in name or ".." in name.split("/") or any(ord(c) < 32 or ord(c) == 127 for c in name)


def read_with_tarfile(path):
	"""The members and the .PKGINFO as Python's tarfile sees them, with the bounds on what a bomb can cost.

	This reader decides nothing by itself: what the host's reader (bsdtar) lists must be the same, member by member."""
	proc = subprocess.Popen(["zstd", "-dc", "-q", "--no-progress", "--", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
	info, members, drained, normal_seen, end, mtree = None, [], False, False, 0, None
	try:
		stream = Capped(proc.stdout, MAX_UNPACKED_BYTES)
		with tarfile.open(fileobj=stream, mode="r|", tarinfo=BoundedInfo) as archive:
			for member in archive:
				if len(members) >= MAX_ENTRIES:
					raise Refused(f"the package has more than {MAX_ENTRIES} entries")
				kind = KINDS.get(member.type)
				if kind is None:
					raise Refused(f"the package has a member of a type that is not a file, folder or link: {member.name!r} ({member.type!r})")
				name = normal_name(member.name)
				if unsafe_name(name):
					raise Refused(f"the package has a member with an unsafe name: {member.name!r}")
				if kind != "-" and member.size != 0:
					raise Refused(f"the package has a member that is not a regular file and has a size: {member.name!r}")
				link = member.linkname if kind in "lh" else ""
				for key in member.pax_headers:
					if key not in PAX_ALLOWED and key not in archive.pax_headers:
						raise Refused(f"the package has a member with an extended attribute or header this channel does not admit: {member.name!r} ({key})")
				if member.mode & 0o6000:
					raise Refused(f"the package has a setuid or setgid member: {member.name!r}")
				if kind == "h" and (link.startswith("/") or ".." in link.split("/")):
					raise Refused(f"the package has a hard link out of its tree: {member.name!r}")
				members.append((kind, name, member.size, link))
				if "/" in name or not name.startswith("."):
					normal_seen = True
				if name == ".PKGINFO":
					if info is not None:
						raise Refused("the package has two .PKGINFO members")
					if normal_seen:
						raise Refused(".PKGINFO comes after the first ordinary entry; it is read only among the leading dot entries")
					if kind != "-" or member.size > MAX_PKGINFO_BYTES:
						raise Refused(".PKGINFO is not a regular file of at most 64 KiB")
					info = archive.extractfile(member).read(MAX_PKGINFO_BYTES + 1)
				if name == ".MTREE":
					if mtree is not None:
						raise Refused("the package has two .MTREE members")
					if kind != "-" or member.size > MAX_MTREE_BYTES:
						raise Refused(".MTREE is not a regular file of at most 8 MiB")
					mtree = read_mtree(archive.extractfile(member).read(MAX_MTREE_BYTES + 1))
			if archive.pax_headers:
				raise Refused("the package carries a global pax header")
			end = archive.offset
		while stream.read(1 << 20):
			pass
		drained = True
		# Nothing may follow the end of the archive but zero blocks, the end mark among them.
		if stream.last_nonzero >= end:
			raise Refused("the package has data after the end of the archive that is not zero blocks")
		if stream.pos < end + 1024:
			raise Refused("the package ends without the two zero blocks that close a tar archive")
	except Refused:
		raise
	except Exception as exc:
		raise Refused(f"the package is not a readable tar.zst: {type(exc).__name__}: {exc}")
	finally:
		proc.stdout.close()
		# A stream read to its end is waited for: zstd may not have exited yet. One that was not read to its end
		# (a refusal, a bomb) is killed, which is what stops the decompression.
		if not drained:
			proc.kill()
		code = proc.wait()
	if code != 0:
		raise Refused(f"zstd could not decompress the package (exit {code})")
	if info is None:
		raise Refused("the package has no .PKGINFO")
	return members, info, mtree


def read_with_bsdtar(path):
	"""The members and the .PKGINFO as the bsdtar of the pinned Arch image sees them: the reader of the host."""
	work = tempfile.mkdtemp(prefix="admit-list.")
	try:
		# Readable by the container and writable only by this user; the container runs as root and needs no more.
		os.chmod(work, 0o755)
		out = os.path.join(work, "out")
		os.mkdir(out, 0o755)
		with open(path, "rb") as src, open(os.path.join(work, "package.pkg.tar.zst"), "wb") as dst:
			while chunk := src.read(1 << 20):
				dst.write(chunk)
		os.chmod(os.path.join(work, "package.pkg.tar.zst"), 0o644)
		try:
			done = subprocess.run(["bash", os.path.join(REPO_ROOT, "scripts/assemble/run-in-arch.sh"), "scripts/admit/list-package.sh", work,
				"/work/package.pkg.tar.zst", "/work/out"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=1200)
		except subprocess.TimeoutExpired:
			raise Refused("the reader of the host took too long over the package")
		if done.returncode == 2:
			raise ConfigError(f"the reader of the host (bsdtar in the Arch image) cannot run: {done.stderr.strip()[-300:]}")
		if done.returncode != 0:
			raise Refused(f"bsdtar could not read the package: {done.stderr.strip()[-300:]}")
		with open(os.path.join(out, "list.txt"), "rb") as f:
			listing = f.read().decode("utf-8", "replace")
		with open(os.path.join(out, "pkginfo"), "rb") as f:
			pkginfo = f.read()
		with open(os.path.join(out, "pax.keys"), "rb") as f:
			pax_keys = f.read().decode("utf-8", "replace")
		mtree_list = None
		if os.path.exists(os.path.join(out, "mtree.list")):
			with open(os.path.join(out, "mtree.list"), "rb") as f:
				mtree_list = f.read().decode("utf-8", "replace")
	finally:
		subprocess.run(["rm", "-rf", "--", work], check=False)
	if listing and not listing.endswith("\n"):
		raise Refused("the listing of the host's reader does not end with a line feed")
	if pax_keys.strip():
		raise Refused("the host's reader sees extended attributes, ACLs or security labels in the package (" + ", ".join(pax_keys.split()[:3]) + ")")
	members = []
	for line in listing.split("\n")[:-1]:
		match = LIST_RE.match(line)
		if not match:
			raise Refused(f"bsdtar listed a member this channel cannot read: {line!r}")
		kind, perms, marker, size, rest = match.groups()
		if marker:
			raise Refused(f"the host's reader sees an extended attribute, an ACL or a security label on a member ({marker}): {line!r}")
		if perms[2] in "sS" or perms[5] in "sS":
			raise Refused(f"the host's reader sees a setuid or setgid member: {line!r}")
		link = ""
		if kind == "l" or kind == "h":
			separator = " -> " if kind == "l" else " link to "
			if rest.count(separator) != 1:
				raise Refused(f"bsdtar listed a link whose name this channel cannot split: {rest!r}")
			rest, link = rest.split(separator)
		if kind not in "-dlh":
			raise Refused(f"the host's reader sees a member that is not a file, folder or link: {line!r}")
		members.append((kind, normal_name(rest), int(size), link))
	mtree = None
	if mtree_list is not None:
		if mtree_list and not mtree_list.endswith("\n"):
			raise Refused("the listing of .MTREE by the host's reader does not end with a line feed")
		mtree = {normal_name(line) for line in mtree_list.split("\n")[:-1]}
	return members, pkginfo, mtree


def read_package(path, rules=None, package=None):
	"""The fields of .PKGINFO, as the host's reader sees them, after the two readers agreed on the whole archive.

	With `rules` (pkgpolicy.load of package-paths.txt) and the name of the package, what it installs is judged too."""
	with open(path, "rb") as f:
		if f.read(4) != ZSTD_MAGIC:
			raise Refused("the package does not start with the zstd magic; it is not a tar.zst and is not handed to a decompressor")
	ours, our_info, mtree = read_with_tarfile(path)
	theirs, their_info, their_mtree = read_with_bsdtar(path)
	if mtree != their_mtree:
		raise Refused(".MTREE lists other paths for the two readers (or only one of them found it)")
	if ours != theirs:
		for number, (a, b) in enumerate(zip(ours, theirs)):
			if a != b:
				raise Refused(f"the two readers disagree on member {number + 1}: tarfile sees {a!r}, bsdtar sees {b!r}")
		raise Refused(f"the two readers disagree on the number of members: {len(ours)} against {len(theirs)}")
	if our_info != their_info:
		raise Refused("the two readers disagree on the content of .PKGINFO")
	try:
		info = parse_pkginfo(their_info.decode("utf-8"))
	except UnicodeDecodeError:
		raise Refused(".PKGINFO is not UTF-8")
	if mtree is not None and mtree != {name for _kind, name, _size, _link in ours if name != ".MTREE"}:
		only_mtree = sorted(mtree - {name for _k, name, _s, _l in ours})
		only_archive = sorted({name for _k, name, _s, _l in ours if name != ".MTREE"} - mtree)
		raise Refused(f".MTREE and the archive do not list the same paths (only in .MTREE: {only_mtree[:3]}, only in the archive: {only_archive[:3]})")
	if rules is not None:
		try:
			pkgpolicy.check(package, rules, ours, info)
		except pkgpolicy.Refused as exc:
			raise Refused(str(exc))
	return info


def main():
	args = sys.argv[1:]
	rules = package = None
	try:
		if len(args) == 5 and args[0] == "--paths" and args[2] == "--package":
			rules, package = pkgpolicy.load(args[1]), args[3]
			args = args[4:]
		elif len(args) == 2 and args[0] == "--no-paths":
			args = args[1:]
		else:
			args = []
		if len(args) != 1:
			print("usage: package-reader.py (--paths <file> --package <name> | --no-paths) <package.pkg.tar.zst>", file=sys.stderr)
			return 2
		print(json.dumps(read_package(args[0], rules, package)))
	except Refused as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	except (ConfigError, pkgpolicy.PolicyError) as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 2
	return 0


if __name__ == "__main__":
	sys.exit(main())
