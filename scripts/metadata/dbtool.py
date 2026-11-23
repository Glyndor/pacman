#!/usr/bin/env python3
"""Read a pacman database and keep the signed state of the repository.

  dbtool.py entries DB
  dbtool.py state-make --previous STATE|- --db DB --now ISO --served SERVED --out FILE
  dbtool.py state-check STATE --db DB --now ISO
  dbtool.py state-get STATE KEY

`entries` prints what a SERVED database says, one package per line and separated by a TAB: name, pkgver, file, compressed
size, sha256, architecture. The database is read like input from a hostile server: every extension header (pax, GNU long
name, sparse) is refused, nothing may follow the end mark of the archive but zero blocks, each `desc` is `%KEY%`, one or more
non-empty lines of value and exactly one blank line, with keys from a closed list, and no control byte. What the repository
SIGNS is not read from anywhere: mkdb.py writes it from what was admitted.

pacman has no expiry or counter in its database, so the repository carries its own: `state-make` writes the
state a signature will cover (a sequence number, the time, when it stops being valid, the hash of the databases
and which packages were replaced and until when they stay), and `state-check` refuses one that is expired, from
the future, or about another database.

Exit 0 done, 1 refused.
"""
import argparse
import datetime
import hashlib
import os
import re
import subprocess
import sys
import tarfile

MAX_DB_BYTES = 64 * 1024 * 1024
MAX_EXTENSION_BYTES = 1 << 20
MAX_DB_ENTRIES = 20000
MAX_DESC_BYTES = 256 * 1024
VALID_DAYS = 14
KEEP_DAYS = VALID_DAYS + 1
FUTURE_SECONDS = 300
FILE_RE = re.compile(r"^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*-[^/\s-]+-[0-9]+-(x86_64|any)\.pkg\.tar\.zst$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
STATE_KEYS = ["glyndor-pacman-state", "repository", "architecture", "sequence", "generated", "valid-until", "db-sha256", "packages"]
CONTROL_ONLY_LF = re.compile(r"[\x00-\x09\x0b-\x1f\x7f]")
DESC_KEYS = {"FILENAME", "NAME", "BASE", "VERSION", "DESC", "GROUPS", "CSIZE", "ISIZE", "SHA256SUM", "URL", "LICENSE", "ARCH", "BUILDDATE",
	"PACKAGER", "REPLACES", "CONFLICTS", "PROVIDES", "DEPENDS", "OPTDEPENDS", "MAKEDEPENDS", "CHECKDEPENDS"}


class Refused(Exception):
	pass


def parse_time(text):
	try:
		return datetime.datetime.strptime(text, TIME_FORMAT).replace(tzinfo=datetime.timezone.utc)
	except ValueError:
		raise Refused(f"'{text}' is not a UTC time of the form 2026-11-23T06:00:00Z")


def sha256_of(path):
	digest = hashlib.sha256()
	with open(path, "rb") as f:
		while chunk := f.read(1 << 20):
			digest.update(chunk)
	return digest.hexdigest()


class Capped:
	"""What tarfile reads, counted: it stops a database that unpacks to more than it should, and remembers where data was."""

	def __init__(self, stream, limit):
		self.stream, self.left = stream, limit
		self.pos, self.last_nonzero = 0, -1

	def read(self, size=-1):
		data = self.stream.read(min(size if size and size > 0 else 1 << 20, self.left + 1))
		self.left -= len(data)
		if self.left < 0:
			raise Refused(f"the database unpacks to more than {MAX_DB_BYTES} bytes")
		stripped = len(data.rstrip(b"\0"))
		if stripped:
			self.last_nonzero = self.pos + stripped - 1
		self.pos += len(data)
		return data


class BoundedInfo(tarfile.TarInfo):
	"""A header with no extension at all: a database this repository writes has none, and the readers differ on them."""

	def _proc_pax(self, archive):
		raise Refused("the database has an extended (pax) header")

	def _proc_gnulong(self, archive):
		raise Refused("the database has a long name header")

	def _proc_sparse(self, archive):
		raise Refused("the database has a sparse member")


def parse_desc(name, text):
	"""{KEY: [values]} of one desc, in the one form this repository writes."""
	if CONTROL_ONLY_LF.search(text):
		raise Refused(f"{name} holds a control character")
	if not text.endswith("\n\n"):
		raise Refused(f"{name} does not end with a value line and a blank line")
	lines = text.split("\n")[:-1]
	entry, i = {}, 0
	while i < len(lines):
		if not re.fullmatch(r"%[A-Z0-9]+%", lines[i]):
			raise Refused(f"{name} has {lines[i]!r} where a key was expected")
		key = lines[i].strip("%")
		if key not in DESC_KEYS:
			raise Refused(f"{name} has a key this repository does not carry: {key}")
		if key in entry:
			raise Refused(f"{name} sets {key} twice")
		i += 1
		values = []
		while i < len(lines) and lines[i] != "":
			values.append(lines[i])
			i += 1
		if not values:
			raise Refused(f"{name} has the key {key} with no value")
		if i >= len(lines):
			raise Refused(f"{name} has the key {key} that is not closed by a blank line")
		entry[key] = values
		i += 1
	return entry


def read_database(path, fields=None):
	"""[(name, pkgver, file, csize, sha256, arch)] from a .db.tar.zst. Only <package>/desc members, with the keys of the list.

	When `fields` is a dict, the keys and values of each desc are put in it under the file name."""
	with open(path, "rb") as f:
		if f.read(4) != bytes.fromhex("28b52ffd"):
			raise Refused(f"{path} does not start with the zstd magic; it is not handed to a decompressor")
	proc = subprocess.Popen(["zstd", "-dc", "-q", "--no-progress", "--", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
	rows, seen, total, drained, folders = [], set(), 0, False, set()
	try:
		stream = Capped(proc.stdout, MAX_DB_BYTES)
		end = 0
		with tarfile.open(fileobj=stream, mode="r|", tarinfo=BoundedInfo) as archive:
			for member in archive:
				total += 1
				if total > MAX_DB_ENTRIES * 2:
					raise Refused("the database has too many entries")
				name = member.name.rstrip("/")
				if member.isdir():
					if "/" in name or not name:
						raise Refused(f"the database has a folder with an odd name: {member.name!r}")
					folders.add(name)
					continue
				folder, _, leaf = name.partition("/")
				if not member.isreg() or leaf != "desc" or not folder:
					raise Refused(f"the database has a member that is not <package>/desc: {member.name!r}")
				if member.size > MAX_DESC_BYTES:
					raise Refused(f"{member.name} is over {MAX_DESC_BYTES} bytes")
				entry = parse_desc(member.name, archive.extractfile(member).read().decode("utf-8"))
				try:
					row = tuple(" ".join(entry[k]) for k in ("NAME", "VERSION", "FILENAME", "CSIZE", "SHA256SUM", "ARCH"))
				except KeyError as exc:
					raise Refused(f"{member.name} has no {exc.args[0]}")
				pname, version, filename, csize, sha, arch = row
				if not FILE_RE.match(filename) or filename != f"{pname}-{version}-{arch}.pkg.tar.zst" or not SHA_RE.match(sha) or not csize.isdigit():
					raise Refused(f"{member.name} describes {filename!r}, which is not a package of this repository")
				if folder != f"{pname}-{version}" or pname in seen:
					raise Refused(f"{member.name} does not match its own entry, or the package {pname} is listed twice")
				seen.add(pname)
				rows.append((pname, version, filename, csize, sha, arch))
				if fields is not None:
					fields[filename] = entry
				if len(rows) > MAX_DB_ENTRIES:
					raise Refused("the database lists too many packages")
			if archive.pax_headers:
				raise Refused("the database has a global pax header")
			if not folders <= {f"{row[0]}-{row[1]}" for row in rows}:
				raise Refused("the database has a folder that is not the one of an entry")
			end = archive.offset
		while stream.read(1 << 20):
			pass
		drained = True
		if stream.last_nonzero >= end:
			raise Refused("the database has data after the end of the archive that is not zero blocks")
		if stream.pos < end + 1024:
			raise Refused("the database ends without the two zero blocks that close a tar archive")
	except Refused:
		raise
	except Exception as exc:
		raise Refused(f"{path} is not a readable database: {type(exc).__name__}: {exc}")
	finally:
		proc.stdout.close()
		if not drained:
			proc.kill()
		proc.wait()
	if proc.returncode != 0:
		raise Refused(f"zstd could not decompress {path}")
	return sorted(rows)


def cmd_entries(args):
	for row in read_database(args.db):
		print("\t".join(row))


def parse_state(path):
	state, retired = {}, []
	with open(path, "rb") as f:
		raw = f.read(1 << 20)
	if any(b != 0x0A and not 0x20 <= b <= 0x7E for b in raw):
		raise Refused(f"{path} holds a byte that is neither printable ASCII nor a line feed")
	for number, line in enumerate(raw.decode("ascii").split("\n"), 1):
		if not line:
			continue
		key, sep, value = line.partition(": ")
		if not sep:
			raise Refused(f"{path}:{number} is not 'key: value'")
		if key == "retired":
			parts = value.split(" ")
			if len(parts) != 3 or not FILE_RE.match(parts[0]):
				raise Refused(f"{path}:{number}: a retired line is '<file> <time> <delete-after>'")
			parse_time(parts[1])
			parse_time(parts[2])
			retired.append(tuple(parts))
		elif key in STATE_KEYS:
			if key in state:
				raise Refused(f"{path} sets {key} twice")
			state[key] = value
		else:
			raise Refused(f"{path}:{number}: unknown key {key}")
	if list(state) != STATE_KEYS:
		raise Refused(f"{path} does not hold exactly {', '.join(STATE_KEYS)} in that order")
	if state["glyndor-pacman-state"] != "1" or state["repository"] != "glyndor" or state["architecture"] != "x86_64":
		raise Refused(f"{path} is not the state of the glyndor x86_64 repository, version 1")
	if not state["sequence"].isdigit() or int(state["sequence"]) < 1 or not state["packages"].isdigit():
		raise Refused(f"{path} has a sequence or a package count that is not a number")
	if not SHA_RE.match(state["db-sha256"]):
		raise Refused(f"{path} has a db-sha256 that is not a sha256")
	return state, retired


def cmd_state_make(args):
	now = parse_time(args.now)
	sequence, retired, previous_time = 1, [], None
	if args.previous != "-":
		state, retired = parse_state(args.previous)
		sequence = int(state["sequence"]) + 1
		previous_time = parse_time(state["generated"])
		if now < previous_time:
			raise Refused(f"the time of this state ({args.now}) is before the one served ({state['generated']})")
	rows = read_database(args.db)
	current = {row[2] for row in rows}
	listed = {item[0] for item in retired}
	with open(args.served) as f:
		for line in f:
			filename = line.rstrip("\n").split("\t")[3]
			if filename not in current and filename not in listed:
				delete_after = now + datetime.timedelta(days=KEEP_DAYS)
				retired.append((filename, now.strftime(TIME_FORMAT), delete_after.strftime(TIME_FORMAT)))
	horizon = now - datetime.timedelta(days=7)
	retired = sorted(item for item in retired if item[0] not in current and parse_time(item[2]) > horizon)
	lines = [
		"glyndor-pacman-state: 1", "repository: glyndor", "architecture: x86_64", f"sequence: {sequence}",
		f"generated: {now.strftime(TIME_FORMAT)}",
		f"valid-until: {(now + datetime.timedelta(days=VALID_DAYS)).strftime(TIME_FORMAT)}",
		f"db-sha256: {sha256_of(args.db)}", f"packages: {len(rows)}",
	]
	lines += [f"retired: {' '.join(item)}" for item in retired]
	fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
	with os.fdopen(fd, "w") as out:
		out.write("\n".join(lines) + "\n")
	print(f"state {sequence}, {len(rows)} package(s), {len(retired)} retired")


def cmd_state_check(args):
	state, _ = parse_state(args.state)
	now = parse_time(args.now)
	if parse_time(state["generated"]) > now + datetime.timedelta(seconds=FUTURE_SECONDS):
		raise Refused(f"the state says it was generated {state['generated']}, which is in the future")
	if parse_time(state["valid-until"]) <= now:
		raise Refused(f"the state expired at {state['valid-until']}")
	if parse_time(state["valid-until"]) - parse_time(state["generated"]) != datetime.timedelta(days=VALID_DAYS):
		raise Refused(f"the state is valid for other than {VALID_DAYS} days")
	if sha256_of(args.db) != state["db-sha256"]:
		raise Refused("the state is about another database than the one served")
	if len(read_database(args.db)) != int(state["packages"]):
		raise Refused("the state counts another number of packages than the database lists")
	print(f"state {state['sequence']} is valid until {state['valid-until']}")


def cmd_state_get(args):
	state, retired = parse_state(args.state)
	if args.key == "retired":
		for item in retired:
			print(" ".join(item))
	elif args.key in state:
		print(state[args.key])
	else:
		raise Refused(f"no key {args.key}")


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = parser.add_subparsers(dest="command", required=True)
	cmd = sub.add_parser("entries")
	cmd.add_argument("db")
	cmd = sub.add_parser("state-make")
	for name in ("previous", "db", "now", "served", "out"):
		cmd.add_argument("--" + name, required=True)
	cmd = sub.add_parser("state-check")
	cmd.add_argument("state")
	cmd.add_argument("--db", required=True)
	cmd.add_argument("--now", required=True)
	cmd = sub.add_parser("state-get")
	cmd.add_argument("state")
	cmd.add_argument("key")
	args = parser.parse_args()
	try:
		{"entries": cmd_entries, "state-make": cmd_state_make, "state-check": cmd_state_check, "state-get": cmd_state_get}[args.command](args)
	except Refused as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	except (OSError, ValueError) as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
