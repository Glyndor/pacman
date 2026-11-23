#!/usr/bin/env python3
"""Decide which pacman packages of one product release this channel admits.

  admit.py plan  --products FILE --repo REPO --tag TAG --assets FILE
  admit.py check --products FILE --repo REPO --tag TAG --assets FILE --dir DIR
                 --ed25519-keys FILE [--mldsa-keys FILE] [--pq-required FILE]
                 [--paths FILE] [--verifier FILE] [--python EXE] --out FILE

`plan` prints, one per line and separated by a TAB, the exact files to download:
kind (package, sig or mldsa), package name, file name, advertised size. Everything
that is not in the exact set derived from the tag and from the products file is
refused, not ignored: a second package, one of another version or architecture, a
name with a path separator or a glob character, an orphan signature.

`check` runs on what was downloaded. It verifies each package against the release
key with verify-sig.py, on a private copy of the bytes, and only then hands that same
copy to package-reader.py, which reads the archive with two readers that must agree and judges what it installs against
package-paths.txt. The fields must say what the file name says, and
the vendor (`packager`) is the one the contract names. It writes the manifest of the
packages it admits.

Exit 0 done, 1 refused, 2 our own configuration is broken (the products file, a key
file), 10 (plan only) the release carries no package of this product at all.
"""
import argparse
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile

REFUSED, CONFIG, NOTHING = 1, 2, 10

MAX_PACKAGE_BYTES = 300 * 1024 * 1024
MAX_SIG_BYTES = 4096
MAX_ASSETS = 1000
CHECK_SECONDS = 600
TOTAL_SECONDS = 1800

PACKAGER = "Glyndor <noreply@glyndor.net>"
RESERVED = {"glyndor-keyring"}
ARCHES = {"x86_64", "any"}
TAG_RE = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+(?:\+r[0-9]+)?)$")
NAME_RE = re.compile(r"^[a-z0-9@_+][a-z0-9@._+-]+$")
REPO_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
PACMAN_ASSET_RE = re.compile(r"\.pkg\.tar(\.|$)", re.I)
SAFE_ASSET_RE = re.compile(r"^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$")
DIGEST_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
RELATION_KEYS = ("provides", "conflict", "conflicts", "replaces")
# What the products file may list for a package: a name, or a name with the exact constraint the package may carry.
RELATION_FORM_RE = re.compile(r"^[a-z0-9@_+][a-z0-9@._+-]+(?:(?:<=|>=|<|>|=)[A-Za-z0-9._+:~-]+)?$")


class Refused(Exception):
	"""The release, or one of its files, is not admitted."""


class ConfigError(Exception):
	"""Something this repository owns is malformed."""


def read_package(path, package, paths):
	"""The fields of .PKGINFO, as package-reader.py read them with the two readers in agreement and the paths allowed."""
	reader = os.path.join(os.path.dirname(os.path.abspath(__file__)), "package-reader.py")
	done = subprocess.run([sys.executable, "-I", reader, "--paths", paths, "--package", package, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=1500)
	if done.returncode == 2:
		raise ConfigError(done.stderr.strip().removeprefix("::error::"))
	if done.returncode != 0:
		raise Refused(done.stderr.strip().removeprefix("::error::") or "the reader of the package failed")
	return json.loads(done.stdout)


def read_products(path, repo):
	"""The packages declared for <repo>: {name: (arches, the relation forms its line lists, literally)}."""
	try:
		with open(path, "rb") as f:
			raw = f.read()
	except OSError as exc:
		raise ConfigError(f"cannot read the products file {path}: {exc}")
	if any(b != 0x0A and b != 0x09 and not 0x20 <= b <= 0x7E for b in raw):
		raise ConfigError(f"{path} holds a byte that is neither printable ASCII, a tab nor a line feed")
	seen, found = set(), {}
	for number, line in enumerate(raw.decode("ascii").split("\n"), 1):
		if not line.strip() or line.startswith("#"):
			continue
		fields = line.split("\t")
		if len(fields) != 4:
			raise ConfigError(f"{path}:{number}: expected four fields separated by a TAB")
		owner, package, arches, relations = fields
		if not REPO_RE.match(owner) or not NAME_RE.match(package) or package in RESERVED:
			raise ConfigError(f"{path}:{number}: '{owner}' or '{package}' is not a usable repository or package name")
		options = arches.split("|")
		if not options or any(a not in ARCHES for a in options) or len(set(options)) != len(options):
			raise ConfigError(f"{path}:{number}: architectures must be x86_64, any or x86_64|any, got '{arches}'")
		allowed = set()
		if relations != "-":
			for name in relations.split(","):
				if not RELATION_FORM_RE.match(name):
					raise ConfigError(f"{path}:{number}: '{name}' is not a package name, or a name with one exact constraint")
				allowed.add(name)
		if package in seen:
			raise ConfigError(f"{path}:{number}: package {package} is declared twice")
		seen.add(package)
		if owner == repo:
			found[package] = (options, allowed)
	if not found:
		raise ConfigError(f"{path} declares no package for the repository {repo}")
	return found


def read_assets(path):
	"""[(name, size, sha256 or None)] from `gh release view --json assets`."""
	try:
		with open(path, "rb") as f:
			data = json.loads(f.read())
		assert isinstance(data, dict)
		listing = data["assets"]
		assert isinstance(listing, list)
	except (OSError, ValueError, KeyError, TypeError, AssertionError) as exc:
		raise Refused(f"the asset listing {path} is not a release listing: {exc}")
	if len(listing) > MAX_ASSETS:
		raise Refused(f"the release lists {len(listing)} assets, over the {MAX_ASSETS} GitHub allows a release")
	assets, names = [], set()
	for item in listing:
		if not isinstance(item, dict):
			raise Refused(f"an asset of the listing is not an object: {item!r}")
		name, size = item.get("name"), item.get("size")
		if not isinstance(name, str) or not name or type(size) is not int or size < 0:
			raise Refused(f"an asset of the listing has no usable name or size: {item!r}")
		if name in names:
			raise Refused(f"the release lists the asset {name} twice")
		names.add(name)
		digest = item.get("digest")
		if digest is not None:
			match = DIGEST_RE.match(str(digest))
			if not match:
				raise Refused(f"the digest of {name} is not a sha256: {digest!r}")
			digest = match.group(1)
		assets.append((name, size, digest))
	return assets


def make_plan(products, repo, tag, assets):
	"""The exact files of this release for this channel: [(kind, package, arch, name, size, digest)]."""
	match = TAG_RE.match(tag)
	if not match:
		raise Refused(f"the tag {tag!r} is not vX.Y.Z or vX.Y.Z+rN; the channel serves stable releases only")
	version = match.group(1)
	expected = {}
	for package, (options, _) in products.items():
		for arch in options:
			base = f"{package}-{version}-1-{arch}.pkg.tar.zst"
			expected[base] = ("package", package, arch)
			expected[base + ".sig"] = ("sig", package, arch)
			expected[base + ".mldsa65.sig"] = ("mldsa", package, arch)
	listed = {name: (size, digest) for name, size, digest in assets}
	for name in listed:
		if PACMAN_ASSET_RE.search(name):
			if not SAFE_ASSET_RE.match(name):
				raise Refused(f"the release carries a package-like asset with an unsafe name: {name!r}")
			if name not in expected:
				raise Refused(f"the release carries {name}, which is not in the set derived from {tag} for {repo}")
	chosen, present = {}, {}
	for package, (options, _) in products.items():
		have = [arch for arch in options if f"{package}-{version}-1-{arch}.pkg.tar.zst" in listed]
		if len(have) > 1:
			raise Refused(f"the release carries {package} for {' and '.join(have)}; exactly one is admitted")
		if have:
			present[package] = have[0]
	for name, (kind, package, arch) in expected.items():
		if name not in listed:
			continue
		if present.get(package) != arch:
			raise Refused(f"{name} has no matching package of the architecture the release carries")
		chosen[name] = (kind, package, arch)
	if not present:
		return []
	missing = sorted(set(products) - set(present))
	if missing:
		raise Refused(f"the release carries {', '.join(sorted(present))} and not {', '.join(missing)}; a product is admitted whole")
	plan = []
	for package, arch in sorted(present.items()):
		base = f"{package}-{version}-1-{arch}.pkg.tar.zst"
		if base + ".sig" not in chosen:
			raise Refused(f"{base} has no .sig beside it")
		for suffix, kind, cap in (("", "package", MAX_PACKAGE_BYTES), (".sig", "sig", MAX_SIG_BYTES), (".mldsa65.sig", "mldsa", MAX_SIG_BYTES)):
			if base + suffix not in chosen:
				continue
			size, digest = listed[base + suffix]
			if size == 0 or size > cap:
				raise Refused(f"{base + suffix} is {size} bytes, outside what a {kind} may be (1 to {cap})")
			plan.append((kind, package, arch, base + suffix, size, digest))
	return plan


def sha256_of(path):
	digest = hashlib.sha256()
	with open(path, "rb") as f:
		while chunk := f.read(1 << 20):
			digest.update(chunk)
	return digest.hexdigest()


def read_list(path, products_file):
	"""The packages whose second signature is required. A list that cannot be read is an error, never an empty list."""
	try:
		if path is None or not stat.S_ISREG(os.stat(path).st_mode):
			raise ConfigError(f"the list of packages that require the second signature, {path}, is not a regular file")
		with open(path, "rb") as f:
			raw = f.read()
	except OSError as exc:
		raise ConfigError(f"cannot read the list of packages that require the second signature: {exc}")
	if any(b != 0x0A and not 0x20 <= b <= 0x7E for b in raw):
		raise ConfigError(f"{path} holds a byte that is neither printable ASCII nor a line feed")
	entries = [line.strip() for line in raw.decode("ascii").split("\n")]
	entries = [e for e in entries if e and not e.startswith("#")]
	declared = set()
	with open(products_file, encoding="ascii") as f:
		for line in f:
			fields = line.rstrip("\n").split("\t")
			if len(fields) == 4 and not line.startswith("#"):
				declared.add(fields[1])
	for entry in entries:
		if not NAME_RE.match(entry):
			raise ConfigError(f"{path}: '{entry}' is not a package name; a comment takes a line of its own")
		if entry not in declared:
			raise ConfigError(f"{path}: '{entry}' is not a package of the products file, so the requirement would apply to nothing")
	return entries


def mldsa_key_configured(path):
	"""True when the file of ML-DSA keys holds anything but comments and blank lines."""
	try:
		with open(path, "rb") as f:
			raw = f.read(1 << 20)
	except FileNotFoundError:
		return False
	except OSError as exc:
		raise ConfigError(f"cannot read the ML-DSA key file {path}: {exc}")
	return any(line.strip() and not line.startswith(b"#") for line in raw.split(b"\n"))


def check_fields(info, package, arch, version, name, allowed, siblings):
	def one(key):
		values = info.get(key)
		return values[0] if values else None

	if one("pkgname") != package or not name.startswith(package + "-"):
		raise Refused(f"{name} declares pkgname {one('pkgname')!r}, expected {package}")
	if one("pkgver") != f"{version}-1":
		raise Refused(f"{name} declares pkgver {one('pkgver')!r}, the release says {version}-1")
	if one("arch") != arch:
		raise Refused(f"{name} declares arch {one('arch')!r} but is named for {arch}")
	if one("packager") != PACKAGER:
		raise Refused(f"{name} declares packager {one('packager')!r}, not '{PACKAGER}'")
	if one("pkgbase") not in (None, package) and one("pkgbase") not in siblings:
		raise Refused(f"{name} declares pkgbase {one('pkgbase')!r}; only the package or another package of its product may be the base")
	for key in ("size", "builddate"):
		if one(key) is not None and not re.fullmatch(r"[0-9]{1,20}", one(key)):
			raise Refused(f"{name} declares a non-numeric {key}")
	for value in info.get("depend", []):
		target = re.split(r"[<>=]", value, maxsplit=1)[0]
		if target in siblings and target != package and value != f"{target}={version}-1":
			raise Refused(f"{name} depends on {value!r}, and a package of the same release must depend on {target}={version}-1 exactly")
	pkgver = f"{version}-1"
	for key in RELATION_KEYS:
		for value in info.get(key, []):
			if not relation_allowed(key, value, package, pkgver, allowed):
				raise Refused(f"{name} lists {value!r} in {key}; only the forms its line of the products file lists are allowed "
					f"(a name, or a name with the exact constraint), and for provides the package itself and a listed name with no version or with {pkgver}")
	for value in info.get("group", []):
		if value not in allowed:
			raise Refused(f"{name} puts itself in the group {value!r}, which its line of the products file does not list")


def relation_allowed(key, value, package, pkgver, allowed):
	"""One relation of .PKGINFO: the form is the package, or what the products file lists, letter for letter.

	A listed name with no constraint also lets `provides` carry the version of this very package, and nothing else."""
	if value == package or value in allowed:
		return True
	if key == "provides":
		name, sep, version = value.partition("=")
		return value == f"{package}={pkgver}" or (bool(sep) and name in allowed and version == pkgver)
	return False


def run_check(args):
	products = read_products(args.products, args.repo)
	assets = read_assets(args.assets)
	plan = make_plan(products, args.repo, args.tag, assets)
	if not plan:
		raise Refused(f"the release {args.tag} of {args.repo} carries no package of the products file")
	required = set(read_list(args.pq_required, args.products))
	if mldsa_key_configured(args.mldsa_keys) and not required:
		raise ConfigError(f"{args.mldsa_keys} holds a key and {args.pq_required} lists no package: the second signature would protect nothing")
	version = TAG_RE.match(args.tag).group(1)
	listing = sorted(os.listdir(args.dir))
	if listing != sorted(entry[3] for entry in plan):
		raise Refused(f"{args.dir} holds {listing}, not the planned set {sorted(entry[3] for entry in plan)}")
	for kind, package, arch, name, size, digest in plan:
		path = os.path.join(args.dir, name)
		st = os.lstat(path)
		if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
			raise Refused(f"{name} is not a regular file with one link")
		if st.st_size != size:
			raise Refused(f"{name} is {st.st_size} bytes, the release says {size}")
		if digest is not None and sha256_of(path) != digest:
			raise Refused(f"{name} does not match the sha256 GitHub lists for it")
	work = tempfile.mkdtemp(prefix="admit.")
	rows, infos = [], {}
	try:
		for package, arch, name in sorted((p, a, n) for kind, p, a, n, s, d in plan if kind == "package"):
			copies = {}
			for kind, owner, _, member, _, _ in plan:
				if owner != package:
					continue
				copy = os.path.join(work, member)
				with open(os.path.join(args.dir, member), "rb") as src:
					data = src.read()
				fd = os.open(copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
				with os.fdopen(fd, "wb") as dst:
					dst.write(data)
				copies[kind] = (copy, hashlib.sha256(data).hexdigest())
			command = [args.python, "-I", args.verifier, copies["package"][0], copies["sig"][0], args.ed25519_keys]
			command += ["--mldsa-sig", os.path.join(work, name + ".mldsa65.sig"), "--mldsa-keys", args.mldsa_keys]
			if package in required:
				command.append("--require-mldsa")
			done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=CHECK_SECONDS)
			if done.returncode == 2:
				raise ConfigError(f"the release key files are broken: {done.stderr.strip()}")
			if done.returncode != 0:
				raise Refused(f"{name} is not signed by the release key: {done.stderr.strip() or done.stdout.strip()}")
			infos[name] = read_package(copies["package"][0], package, args.paths)
			check_fields(infos[name], package, arch, version, name, products[package][1], set(products))
			if sha256_of(os.path.join(args.dir, name)) != copies["package"][1]:
				raise Refused(f"{name} changed while it was being verified")
			rows.append((args.repo, package, f"{version}-1", arch, name, str(os.lstat(os.path.join(args.dir, name)).st_size),
				copies["package"][1], "yes" if "mldsa" in copies else "no"))
	finally:
		for entry in os.listdir(work):
			os.unlink(os.path.join(work, entry))
		os.rmdir(work)
	# What the packages say, beside the manifest: the signer compares the database with it and opens no archive.
	fd = os.open(args.out + ".pkginfo.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
	with os.fdopen(fd, "w") as out:
		json.dump(infos, out, sort_keys=True)
	fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
	with os.fdopen(fd, "w") as out:
		for row in rows:
			out.write("\t".join(row) + "\n")
	print(f"admitted {len(rows)} package(s) of {args.repo} {args.tag}")


def run_plan(args):
	products = read_products(args.products, args.repo)
	plan = make_plan(products, args.repo, args.tag, read_assets(args.assets))
	if not plan:
		print(f"::notice::the release {args.tag} of {args.repo} carries no pacman package", file=sys.stderr)
		return NOTHING
	for kind, package, arch, name, size, digest in plan:
		print(f"{kind}\t{package}\t{name}\t{size}")
	return 0


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = parser.add_subparsers(dest="command", required=True)
	for name in ("plan", "check"):
		cmd = sub.add_parser(name)
		cmd.add_argument("--products", required=True)
		cmd.add_argument("--repo", required=True)
		cmd.add_argument("--tag", required=True)
		cmd.add_argument("--assets", required=True)
	check = sub.choices["check"]
	check.add_argument("--dir", required=True)
	check.add_argument("--ed25519-keys", required=True)
	check.add_argument("--mldsa-keys", default=os.devnull)
	check.add_argument("--pq-required", required=True)
	check.add_argument("--paths", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "package-paths.txt"))
	check.add_argument("--verifier", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify-sig.py"))
	check.add_argument("--python", default=sys.executable)
	check.add_argument("--out", required=True)
	args = parser.parse_args()

	def too_slow(signum, frame):
		raise Refused(f"the admission took more than {TOTAL_SECONDS} seconds")

	signal.signal(signal.SIGALRM, too_slow)
	signal.alarm(TOTAL_SECONDS)
	try:
		if args.command == "plan":
			return run_plan(args)
		run_check(args)
		return 0
	except Refused as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return REFUSED
	except subprocess.TimeoutExpired as exc:
		print(f"::error::{exc.cmd[0]} took more than {CHECK_SECONDS} seconds; refusing the release", file=sys.stderr)
		return REFUSED
	except (ConfigError, OSError) as exc:
		print(f"::error::{exc}", file=sys.stderr)
		return CONFIG


if __name__ == "__main__":
	sys.exit(main())
