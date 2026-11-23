#!/usr/bin/env python3
"""Write the database of the repository from what was admitted, byte for byte the same for the same input.

  mkdb.py --manifest FILE --pkginfo FILE --packages DIR --out FILE

The key of the repository signs this file, so nothing in it comes from a tool that ran over the packages. Each entry is
made here from the manifest of the admission (name, version, file, size, sha256, architecture) and from the `.PKGINFO` the
admission read, key by key, in the order and the form repo-add writes them; the entries are sorted by name, and every field
of the archive (times, owners, modes, order, compression) is fixed. repo-add of the pinned image is run over the same
packages in the tests, and its `desc` must be the same text; pacman reads the file in a real container.

The packages in DIR must be exactly the admitted ones, regular files with the size and the hash of the manifest.

Exit 0 written, 1 refused.
"""
import argparse
import hashlib
import io
import json
import os
import re
import stat
import subprocess
import sys
import tarfile

NAME_RE = re.compile(r"^[a-z0-9@_+][a-z0-9@._+-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
# What repo-add writes for each key of .PKGINFO, in the order it writes the sections (measured with the repo-add of the pinned image).
ORDER = ["FILENAME", "NAME", "BASE", "VERSION", "DESC", "GROUPS", "CSIZE", "ISIZE", "SHA256SUM", "URL", "LICENSE", "ARCH", "BUILDDATE",
	"PACKAGER", "REPLACES", "CONFLICTS", "PROVIDES", "DEPENDS", "OPTDEPENDS", "MAKEDEPENDS", "CHECKDEPENDS"]
FROM_PKGINFO = {"pkgbase": "BASE", "pkgdesc": "DESC", "group": "GROUPS", "size": "ISIZE", "url": "URL", "license": "LICENSE", "builddate": "BUILDDATE",
	"packager": "PACKAGER", "replaces": "REPLACES", "conflict": "CONFLICTS", "provides": "PROVIDES", "depend": "DEPENDS", "optdepend": "OPTDEPENDS",
	"makedepend": "MAKEDEPENDS", "checkdepend": "CHECKDEPENDS"}
# Keys of .PKGINFO that are read and not written: the identity, which the manifest already holds, and what pacman does not keep in a database.
NOT_WRITTEN = {"pkgname", "pkgver", "arch", "xdata", "backup"}


class Refused(Exception):
	pass


def sha256_of(path):
	digest = hashlib.sha256()
	with open(path, "rb") as f:
		while chunk := f.read(1 << 20):
			digest.update(chunk)
	return digest.hexdigest()


def read_manifest(path):
	rows = []
	with open(path, encoding="ascii") as f:
		for line in f:
			fields = line.rstrip("\n").split("\t")
			if len(fields) != 8:
				raise Refused(f"a row of the manifest has {len(fields)} fields, not eight")
			_repo, package, pkgver, arch, filename, size, sha, _pq = fields
			if not NAME_RE.match(package) or arch not in ("x86_64", "any") or not size.isdigit() or not SHA_RE.match(sha):
				raise Refused(f"the manifest row of {filename!r} is not well formed")
			if filename != f"{package}-{pkgver}-{arch}.pkg.tar.zst" or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?-1", pkgver):
				raise Refused(f"the manifest row of {filename!r} does not say what its file name says")
			rows.append((package, pkgver, arch, filename, size, sha))
	if not rows:
		raise Refused("the manifest is empty; refusing to write an empty repository")
	if len({row[0] for row in rows}) != len(rows):
		raise Refused("the manifest lists a package twice")
	return sorted(rows)


def desc_of(row, info):
	package, pkgver, arch, filename, size, sha = row
	for key, values in info.items():
		if key not in FROM_PKGINFO and key not in NOT_WRITTEN:
			raise Refused(f"the .PKGINFO of {filename} has a key the database does not carry: {key}")
		if not isinstance(values, list) or not values or any(not isinstance(v, str) or not v or CONTROL_RE.search(v) for v in values):
			raise Refused(f"the .PKGINFO of {filename} has a value that is empty, not text or holds a control character: {key}")
	if info.get("pkgname") != [package] or info.get("pkgver") != [pkgver] or info.get("arch") != [arch]:
		raise Refused(f"the .PKGINFO of {filename} does not say what the manifest says of its name, version and architecture")
	fields = {"FILENAME": [filename], "NAME": [package], "VERSION": [pkgver], "CSIZE": [size], "SHA256SUM": [sha], "ARCH": [arch]}
	for key, desc_key in FROM_PKGINFO.items():
		if key in info:
			fields[desc_key] = list(info[key])
	return "".join(f"%{key}%\n" + "\n".join(fields[key]) + "\n\n" for key in ORDER if key in fields)


def check_packages(rows, folder):
	names = sorted(e for e in os.listdir(folder) if e.endswith(".pkg.tar.zst"))
	if names != sorted(row[3] for row in rows):
		raise Refused(f"{folder} holds {names}, not the admitted packages")
	for package, pkgver, arch, filename, size, sha in rows:
		path = os.path.join(folder, filename)
		st = os.lstat(path)
		if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size != int(size) or sha256_of(path) != sha:
			raise Refused(f"{filename} is not the admitted file (a link, or another size or hash)")


def build(rows, infos):
	buffer = io.BytesIO()
	with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
		for row in rows:
			package, pkgver, arch, filename, size, sha = row
			info = infos.get(filename)
			if not isinstance(info, dict):
				raise Refused(f"no .PKGINFO was read for {filename}")
			entry = f"{package}-{pkgver}"
			body = desc_of(row, info).encode("utf-8")
			folder = tarfile.TarInfo(entry)
			folder.type, folder.mode = tarfile.DIRTYPE, 0o755
			member = tarfile.TarInfo(f"{entry}/desc")
			member.size, member.mode = len(body), 0o644
			for item in (folder, member):
				item.mtime, item.uid, item.gid, item.uname, item.gname = 0, 0, 0, "root", "root"
			archive.addfile(folder)
			archive.addfile(member, io.BytesIO(body))
	return subprocess.run(["zstd", "-q", "-19", "-T1", "-c"], input=buffer.getvalue(), stdout=subprocess.PIPE, check=True).stdout


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	for name in ("manifest", "pkginfo", "packages", "out"):
		parser.add_argument("--" + name, required=True)
	args = parser.parse_args()
	try:
		rows = read_manifest(args.manifest)
		with open(args.pkginfo, "rb") as f:
			infos = json.loads(f.read())
		check_packages(rows, args.packages)
		data = build(rows, infos)
		fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
		with os.fdopen(fd, "wb") as out:
			out.write(data)
	except Refused as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	except (OSError, ValueError, subprocess.CalledProcessError) as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	print(f"wrote the database of {len(rows)} admitted package(s)")
	return 0


if __name__ == "__main__":
	sys.exit(main())
