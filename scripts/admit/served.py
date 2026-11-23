#!/usr/bin/env python3
"""Read the list of what the repository serves, and compare the admitted packages with it.

  served.py --served FILE --manifest FILE [--allow-empty]

Every line of the list is exactly name, pkgver, sha256 and file, separated by a TAB, the last line is ended, nothing
else is a line, and a package is listed once. An empty list is refused unless the run is the first publication. An
admitted package older than the served one is refused (the numbers of X.Y.Z[+rN]-1, not text), and so is the same
version with other bytes: a published identity does not change bytes and a version never goes backwards.

Exit 0 done, 1 refused.
"""
import argparse
import re
import sys


class Refused(Exception):
	"""The list, or the comparison, is not acceptable."""


SERVED_RE = re.compile(r"^([a-z0-9@_+][a-z0-9@._+-]+)\t([0-9]+\.[0-9]+\.[0-9]+(?:\+r[0-9]+)?-1)\t([0-9a-f]{64})\t([^\t/]+)$")
PKGVER_RE = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+r([0-9]+))?-1$")
MAX_SERVED_BYTES = 16 * 1024 * 1024


def version_key(pkgver):
	match = PKGVER_RE.match(pkgver)
	if not match:
		raise Refused(f"{pkgver!r} is not of the form X.Y.Z[+rN]-1")
	return tuple(int(part or 0) for part in match.groups())


def read_served(path, allow_empty):
	"""[(name, pkgver, sha256, file)] of what is served, every line exactly that and the last one ended."""
	try:
		with open(path, "rb") as f:
			raw = f.read(MAX_SERVED_BYTES + 1)
	except OSError as exc:
		raise Refused(f"cannot read the list of what is served: {exc}")
	if len(raw) > MAX_SERVED_BYTES:
		raise Refused(f"the list of what is served is larger than {MAX_SERVED_BYTES} bytes; a part of it is not read, and a part of it is not compared")
	if not raw:
		if allow_empty:
			return []
		raise Refused("the list of what is served is empty and this is not the first publication")
	if not raw.endswith(b"\n"):
		raise Refused(f"{path} does not end with a line feed; its last line may be cut")
	rows = []
	for number, line in enumerate(raw.decode("ascii", "replace").split("\n")[:-1], 1):
		match = SERVED_RE.match(line)
		if not match:
			raise Refused(f"{path}:{number} is not 'name<TAB>pkgver<TAB>sha256<TAB>file'")
		name, pkgver, sha, filename = match.groups()
		if not filename.startswith(f"{name}-{pkgver}-") or not filename.endswith(".pkg.tar.zst"):
			raise Refused(f"{path}:{number}: {filename} is not the file of {name} {pkgver}")
		rows.append(match.groups())
	if len({row[0] for row in rows}) != len(rows):
		raise Refused(f"{path} lists a package twice")
	return rows


def run_served(args):
	served = read_served(args.served, args.allow_empty)
	with open(args.manifest) as f:
		candidates = [line.rstrip("\n").split("\t") for line in f if line.strip()]
	for _repo, package, pkgver, _arch, _file, _size, sha, _pq in candidates:
		for name, served_ver, served_sha, _served_file in served:
			if name != package:
				continue
			if version_key(pkgver) < version_key(served_ver):
				raise Refused(f"{package} {pkgver} is older than {served_ver}, which is served; a version never goes backwards")
			if version_key(pkgver) == version_key(served_ver) and sha != served_sha:
				raise Refused(f"{package} {pkgver} is served with another SHA-256 than the release carries; bytes that change need a new version")
	print(f"{len(served)} served package(s) read, none newer than what was admitted")


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("--served", required=True)
	parser.add_argument("--manifest", required=True)
	parser.add_argument("--allow-empty", action="store_true")
	args = parser.parse_args()
	try:
		run_served(args)
	except (Refused, OSError) as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
