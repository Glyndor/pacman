#!/usr/bin/env python3
"""Judge the keyring package that a container built, and say what the manifest and the database may know of it.

  check-keyring.py --package FILE --epoch SECONDS --key ASC

What comes out of a container is data nobody trusts, so nothing of it is believed. The only name accepted is the one
derived here from the epoch (glyndor-keyring-1.0.<epoch>-1-any.pkg.tar.zst); the file must be that name, a regular file
with one link; its size and sha256 are computed here; the two readers of the admission (package-reader.py) read it; its
.PKGINFO must be exactly the fixed values below (only `size` is read, and it is a number); and its members must be the
fixed list, with the fixed metadata (owner 0:0 and no names, mode 0755 for folders and 0644 for files, the time of the
epoch, no extended header, no link or device) and the fixed bytes: .INSTALL as written here, an empty revocation list, the trust file naming the
fingerprint of the key of the repository, and a keyring file that holds that key and nothing else.

Last, the package is rebuilt here from what it holds, with the same GNU tar options that build-keyring.sh uses, and the
tar stream must be the same bytes as the one in the package: whatever a field-by-field list could miss, this does not.

Prints one JSON object (file, pkgver, size, sha256, pkginfo) on stdout. Exit 0 accepted, 1 refused, 2 usage.
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
import tempfile
import shutil

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
READER = os.path.join(HERE, "scripts", "admit", "package-reader.py")
PACKAGER = "Glyndor <noreply@glyndor.net>"
DESCRIPTION = "The key that signs the Glyndor pacman repository"
URL = "https://pacman.glyndor.net"
INSTALL = b"post_install() {\n\tpacman-key --populate glyndor\n}\n\npost_upgrade() {\n\tpacman-key --populate glyndor\n}\n"
KEYRINGS = "usr/share/pacman/keyrings/"
MEMBERS = [".PKGINFO", ".INSTALL", "usr", "usr/share", "usr/share/pacman", "usr/share/pacman/keyrings",
	KEYRINGS + "glyndor-revoked", KEYRINGS + "glyndor-trusted", KEYRINGS + "glyndor.gpg"]
MAX_KEYRING_BYTES = 64 * 1024


class Refused(Exception):
	pass


def fingerprint_of(key_bytes):
	"""The fingerprints of the public keys in these bytes, from gpg in an empty home, and nothing about secret keys."""
	home = tempfile.mkdtemp()
	try:
		os.chmod(home, 0o700)
		out = subprocess.run(["gpg", "--homedir", home, "--batch", "--with-colons", "--import-options", "show-only", "--import"],
			input=key_bytes, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False).stdout.decode("utf-8", "replace")
		subprocess.run(["gpgconf", "--homedir", home, "--kill", "all"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
	finally:
		shutil.rmtree(home, ignore_errors=True)
	rows = [line.split(":") for line in out.splitlines()]
	kinds = [row[0] for row in rows]
	if any(kind in ("sec", "ssb") for kind in kinds):
		raise Refused("the keyring file holds a secret key")
	fingerprints = [row[9] for row in rows if row[0] == "fpr" and len(row) > 9]
	primaries = [row for row in rows if row[0] == "pub"]
	if len(primaries) != 1 or not fingerprints or not re.fullmatch(r"[0-9A-F]{40}", fingerprints[0]):
		raise Refused("the keyring file does not hold exactly one public key")
	return fingerprints[0]


def read_members(path, epoch):
	"""{name: (type, bytes)} of the package, which package-reader.py has already shown is a plain archive."""
	found = {}
	proc = subprocess.Popen(["zstd", "-dc", "-q", "--", path], stdout=subprocess.PIPE)
	data = proc.stdout.read(4 * 1024 * 1024 + 1)
	proc.stdout.close()
	proc.wait()
	if proc.returncode != 0 or len(data) > 4 * 1024 * 1024:
		raise Refused("the package does not unpack, or unpacks to more than 4 MiB")
	with tarfile.open(fileobj=io.BytesIO(data)) as archive:
		order = []
		for member in archive:
			name = member.name.rstrip("/")
			order.append(name)
			if member.isdir():
				want_mode = 0o755
			elif member.isreg():
				want_mode = 0o644
			else:
				raise Refused(f"{name} is neither a regular file nor a folder")
			if member.mode != want_mode:
				raise Refused(f"{name} has mode {oct(member.mode)}, not {oct(want_mode)}")
			if (member.uid, member.gid) != (0, 0) or member.uname or member.gname:
				raise Refused(f"{name} has an owner other than the numeric 0:0 with no names")
			if member.mtime != int(epoch):
				raise Refused(f"{name} has the time {member.mtime}, not the epoch {epoch}")
			if member.pax_headers or member.linkname or member.devmajor or member.devminor:
				raise Refused(f"{name} has an extended header, a link target or a device number")
			if member.isdir():
				found[name] = ("dir", b"")
			elif member.isreg():
				if member.size > MAX_KEYRING_BYTES:
					raise Refused(f"{name} is larger than {MAX_KEYRING_BYTES} bytes")
				found[name] = ("file", archive.extractfile(member).read())
			else:
				raise Refused(f"{name} is neither a regular file nor a folder")
	if order != MEMBERS or len(found) != len(MEMBERS):
		raise Refused(f"the members of the package are {order}, not the fixed list")
	return found, data


def rebuild(members, epoch):
	"""The tar stream that build-keyring.sh would write for these members, made here with GNU tar."""
	root = tempfile.mkdtemp()
	try:
		for name in MEMBERS:
			kind, content = members[name]
			path = os.path.join(root, name)
			if kind == "dir":
				os.makedirs(path, exist_ok=True)
				os.chmod(path, 0o755)
			else:
				with open(path, "wb") as f:
					f.write(content)
				os.chmod(path, 0o644)
		return subprocess.run(["tar", "--sort=name", "--format=gnu", f"--mtime=@{epoch}", "--owner=0", "--group=0", "--numeric-owner",
			"--no-recursion", "-cf", "-", *MEMBERS], cwd=root, stdout=subprocess.PIPE, check=True, env={"LC_ALL": "C", "PATH": os.environ["PATH"]}).stdout
	finally:
		shutil.rmtree(root, ignore_errors=True)


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("--package", required=True)
	parser.add_argument("--epoch", required=True)
	parser.add_argument("--key", required=True)
	args = parser.parse_args()
	if not re.fullmatch(r"[1-9][0-9]{8,10}", args.epoch):
		print("::error::the epoch is a number of seconds", file=sys.stderr)
		return 2
	pkgver = f"1.0.{args.epoch}"
	file = f"glyndor-keyring-{pkgver}-1-any.pkg.tar.zst"
	try:
		if os.path.basename(args.package) != file:
			raise Refused(f"the package is called {os.path.basename(args.package)!r}; the only name accepted is {file!r}")
		st = os.lstat(args.package)
		if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
			raise Refused(f"{file} is not a regular file with one link")
		digest = hashlib.sha256()
		with open(args.package, "rb") as f:
			while chunk := f.read(1 << 20):
				digest.update(chunk)
		with open(args.key, "rb") as f:
			key_bytes = f.read()
		fingerprint = fingerprint_of(key_bytes)
		proc = subprocess.run(["python3", "-I", READER, "--no-paths", args.package], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
		if proc.returncode != 0:
			raise Refused("the readers of the admission refused the package: " + proc.stderr.decode("utf-8", "replace").strip())
		info = json.loads(proc.stdout)
		fixed = {"pkgname": ["glyndor-keyring"], "pkgbase": ["glyndor-keyring"], "pkgver": [f"{pkgver}-1"], "pkgdesc": [DESCRIPTION], "url": [URL],
			"builddate": [args.epoch], "packager": [PACKAGER], "arch": ["any"], "license": ["MIT"], "depend": ["pacman"]}
		size = info.pop("size", None)
		if not (isinstance(size, list) and len(size) == 1 and re.fullmatch(r"[0-9]{1,9}", size[0])):
			raise Refused("the .PKGINFO has no size, or one that is not a number")
		if info != fixed:
			raise Refused(f"the .PKGINFO says {sorted(info)} where the fixed fields were expected, or a value that is not the fixed one")
		info["size"] = size
		members, stream = read_members(args.package, args.epoch)
		if members[".INSTALL"] != ("file", INSTALL):
			raise Refused(".INSTALL is not the fixed script")
		if members[KEYRINGS + "glyndor-revoked"] != ("file", b""):
			raise Refused("the revocation list is not empty")
		if members[KEYRINGS + "glyndor-trusted"] != ("file", f"{fingerprint}:4:\n".encode()):
			raise Refused("the trust file does not name exactly the fingerprint of the key of the repository, fully trusted")
		kind, ring = members[KEYRINGS + "glyndor.gpg"]
		if kind != "file" or fingerprint_of(ring) != fingerprint:
			raise Refused("the keyring file does not hold the key of the repository and nothing else")
		if rebuild(members, args.epoch) != stream:
			raise Refused("the package is not, byte for byte, the tar stream that build-keyring.sh writes for what it holds")
		print(json.dumps({"file": file, "pkgver": f"{pkgver}-1", "size": st.st_size, "sha256": digest.hexdigest(), "pkginfo": info}))
	except Refused as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	except (OSError, ValueError, tarfile.TarError) as exc:
		print(f"::error::{type(exc).__name__}: {exc}", file=sys.stderr)
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
