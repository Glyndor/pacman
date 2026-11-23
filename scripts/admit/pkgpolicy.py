"""Which paths a package may install, and where its links may point. Default deny.

Used by package-reader.py on the members both readers agreed on. The rules are in package-paths.txt, one line per package:

  <package> TAB <pattern> SPACE <pattern> ...

A pattern is a path without a leading slash. `*` stands for any characters inside one component. A pattern that ends with
`/` is a folder and everything under it. A pattern that starts with `>` is only a place a link may point at (a file that
another package of the same release installs). Nothing else is allowed: a member that no pattern names refuses the package,
and what is in FORBIDDEN refuses it even when a pattern names it (a mistake in the file cannot open pacman's own files).
"""
import fnmatch
import posixpath
import re

# Never installed by a product package, whatever package-paths.txt says: the configuration, keys and hooks of pacman, and
# the files that decide who can become root or what runs at boot or on login.
FORBIDDEN = ("etc/pacman.conf", "etc/pacman.d", "usr/share/pacman", "usr/share/libalpm", "var/lib/pacman", "etc/sudoers", "etc/sudoers.d",
	"etc/passwd", "etc/shadow", "etc/group", "etc/gshadow", "etc/pam.d", "etc/ld.so.conf", "etc/ld.so.conf.d", "etc/profile",
	"etc/profile.d", "etc/cron.d", "etc/crontab", "etc/cron.daily", "etc/cron.hourly", "etc/cron.weekly", "etc/cron.monthly",
	"etc/ssh", "etc/systemd", "usr/lib/udev/rules.d", "etc/udev", "usr/lib/modprobe.d", "etc/modprobe.d", "boot")
DOT_ENTRIES = (".PKGINFO", ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG")
NAME_RE = re.compile(r"^[a-z0-9@_+][a-z0-9@._+-]+$")
PATTERN_RE = re.compile(r"^>?[A-Za-z0-9@_+*][A-Za-z0-9@._+*-]*(/[A-Za-z0-9@_+*][A-Za-z0-9@._+*-]*)*/?$")


class PolicyError(Exception):
	"""package-paths.txt is malformed, or names something that is never allowed."""


class Refused(Exception):
	"""A package does not stay inside its paths."""


def components(path):
	return [part for part in path.split("/") if part]


def forbidden(path):
	comps = components(path)
	return any(comps[: len(components(entry))] == components(entry) for entry in FORBIDDEN) if comps else False


def load(path):
	"""{package: [pattern, ...]} from the file; any line that is not exactly package, TAB, patterns is an error."""
	try:
		with open(path, "rb") as f:
			raw = f.read(1 << 20)
	except OSError as exc:
		raise PolicyError(f"cannot read the paths file {path}: {exc}")
	if any(b != 0x0A and b != 0x09 and not 0x20 <= b <= 0x7E for b in raw):
		raise PolicyError(f"{path} holds a byte that is neither printable ASCII, a tab nor a line feed")
	rules = {}
	for number, line in enumerate(raw.decode("ascii").split("\n"), 1):
		if not line.strip() or line.startswith("#"):
			continue
		fields = line.split("\t")
		if len(fields) != 2 or not NAME_RE.match(fields[0]):
			raise PolicyError(f"{path}:{number}: expected a package name, a TAB and patterns")
		if fields[0] in rules:
			raise PolicyError(f"{path}:{number}: {fields[0]} has two lines")
		patterns = fields[1].split(" ")
		for pattern in patterns:
			if not PATTERN_RE.match(pattern) or ".." in pattern.split("/"):
				raise PolicyError(f"{path}:{number}: '{pattern}' is not a path pattern")
			if forbidden(pattern.lstrip(">").replace("*", "x")):
				raise PolicyError(f"{path}:{number}: '{pattern}' is a place no product package may install")
		rules[fields[0]] = patterns
	return rules


def _match(pattern_comps, comps):
	return all(fnmatch.fnmatchcase(c, p) for c, p in zip(comps, pattern_comps))


def _split(patterns):
	own = [(components(p), p.endswith("/")) for p in patterns if not p.startswith(">")]
	targets = [(components(p[1:]), p.endswith("/")) for p in patterns if p.startswith(">")]
	return own, targets


def allowed_file(name, entries):
	comps = components(name)
	for pc, tree in entries:
		if tree and len(comps) > len(pc) and _match(pc, comps):
			return True
		if not tree and len(comps) == len(pc) and _match(pc, comps):
			return True
	return False


def allowed_folder(name, entries):
	"""A folder is allowed when it is on the way to something allowed, or is allowed itself."""
	comps = components(name)
	for pc, tree in entries:
		if len(comps) <= len(pc) and _match(pc, comps):
			return True
		if tree and len(comps) > len(pc) and _match(pc, comps):
			return True
	return False


def resolve(link_name, target):
	"""The path inside the package that a link points at, or None when the target is not one this channel accepts.

	The rule is strict because the kernel follows links component by component and a lexical reading would not agree with it: an
	absolute target with `.` or `..`, a `..` after a component that is not `..`, and a target that leaves the tree are refused."""
	parts = target.split("/")
	if target.startswith("/"):
		if any(part in (".", "..") for part in parts):
			return None
		base = target.lstrip("/")
	else:
		seen_name = False
		for part in parts:
			if part == "..":
				if seen_name:
					return None
			elif part not in ("", "."):
				seen_name = True
		base = posixpath.join(posixpath.dirname(link_name), target)
	joined = posixpath.normpath(base)
	if joined in (".", "") or joined == ".." or joined.startswith("../"):
		return None
	return joined


MAX_HOPS = 8


def check(package, rules, members, info):
	"""Refuse a package that installs, links or backs up anything its line does not allow."""
	if package not in rules:
		raise Refused(f"package-paths.txt has no line for {package}; a package with no allowed paths installs nothing")
	own, targets = _split(rules[package])
	reachable = own + targets
	names, links = {}, {}
	for kind, name, _size, link in members:
		if name in DOT_ENTRIES:
			if kind != "-":
				raise Refused(f"{name} is not a regular file")
			continue
		if name in names:
			raise Refused(f"{name} is in the package twice")
		names[name] = kind
		if kind in "lh":
			links[name] = (kind, link)
	for kind, name, _size, link in members:
		if name in DOT_ENTRIES:
			continue
		if forbidden(name):
			raise Refused(f"{name} is a place no product package may install (the files and keys of pacman, of sudo, of the login)")
		comps = components(name)
		for number in range(1, len(comps)):
			if names.get("/".join(comps[:number])) in ("l", "h"):
				raise Refused(f"{name} is inside {'/'.join(comps[:number])}, which is a link of the same package: where it lands depends on the system")
		if kind == "d":
			if not allowed_folder(name, own):
				raise Refused(f"{name} is not a place the package {package} may install")
			continue
		if not allowed_file(name, own):
			raise Refused(f"{name} is not a place the package {package} may install")
		if kind in "lh":
			follow(name, kind, link, package, names, links, own, reachable)
	for value in info.get("backup", []):
		if value.startswith("/") or ".." in value.split("/") or not allowed_file(value, own):
			raise Refused(f".PKGINFO backup names {value!r}, which is not a file the package {package} may install")


def follow(name, kind, link, package, names, links, own, reachable):
	"""A link and, if it points at another link of the package, the one after it, to the end, with a limit of hops."""
	here, target, hops = name, link, 0
	while True:
		where = resolve(here, target) if links[here][0] == "l" else resolve("x", target)
		if where is None or forbidden(where):
			raise Refused(f"{here} links to {target!r}, which is outside the package, a place no package may install, or a target that the kernel could read otherwise")
		comps = components(where)
		for number in range(1, len(comps)):
			if names.get("/".join(comps[:number])) in ("l", "h"):
				raise Refused(f"{here} links to {target!r}, through {'/'.join(comps[:number])}, which is a link of the same package")
		if not (allowed_file(where, reachable) or allowed_file(where + "/x", reachable)):
			raise Refused(f"{here} links to {target!r}, which is not a place the package {package} may install or point at")
		if where not in links:
			return
		hops += 1
		if hops > MAX_HOPS:
			raise Refused(f"{name} leads through more than {MAX_HOPS} links")
		here = where
		target = links[where][1]
