#!/usr/bin/env bash
#
# check-keyring.py: what comes out of a container is data nobody trusts. A real keyring package is built once in the pinned
# image and accepted; then each way a hostile build could differ from it is made by rewriting that package, and each is
# refused with the reason: another name, a link, a second hard link, an extra or missing member, a field of .PKGINFO that
# is not the fixed one (a relation, a replaces, another version), a changed .INSTALL, a revocation list that is not empty,
# a trust file that names another key or a second one, a keyring file with another key, two, or a secret one.
#
# Requires: docker or podman, gpg, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
TOOL="$HERE/scripts/keyring/check-keyring.py"
KEY="$HERE/keyring/glyndor-pacman-key.asc"
EPOCH=1700000000
F="glyndor-keyring-1.0.$EPOCH-1-any.pkg.tar.zst"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; if grep -q Traceback "$WORK/last.out"; then rc=99; fi; echo "$rc"; }
says() { if grep -q -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }
judge() { python3 -I "$TOOL" --package "$1" --epoch "${2:-$EPOCH}" --key "${3:-$KEY}"; }

mkdir -p "$WORK/w"
chmod 777 "$WORK/w"
cp "$KEY" "$WORK/w/key.asc"
chmod 644 "$WORK/w/key.asc"
bash "$HERE/scripts/assemble/run-in-arch.sh" scripts/keyring/build-keyring.sh "$WORK/w" --key /work/key.asc --epoch "$EPOCH" --out /work/good > /dev/null
GOOD="$WORK/w/good/$F"
make_gpg_key "$WORK/other"
make_gpg_key "$WORK/third"

check "the package built in the image is accepted" "0" "$(rc_of judge "$GOOD")"
check "and the verdict gives the name, the version, the size and the hash computed here" "$F 1.0.$EPOCH-1 $(stat -c%s "$GOOD") $(sha256sum "$GOOD" | cut -d' ' -f1)" \
	"$(python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["file"], d["pkgver"], d["size"], d["sha256"])' < "$WORK/last.out")"
check "with the fields of .PKGINFO that the database carries" "glyndor-keyring any MIT pacman" \
	"$(python3 -I -c 'import json,sys; d=json.load(sys.stdin)["pkginfo"]; print(d["pkgname"][0], d["arch"][0], d["license"][0], d["depend"][0])' < "$WORK/last.out")"

# remake <out dir> <python statements over `m` (the ordered list of [name, kind, bytes])>: the package with those changes
remake() {
	mkdir -p "$1"
	python3 -I - "$GOOD" "$1/${NAME:-$F}" "$2" <<'PY'
import io, subprocess, sys, tarfile
good, out, body = sys.argv[1:4]
data = subprocess.run(["zstd", "-dc", "-q", good], stdout=subprocess.PIPE, check=True).stdout
m = []
with tarfile.open(fileobj=io.BytesIO(data)) as archive:
	for member in archive:
		m.append([member.name.rstrip("/"), "dir" if member.isdir() else "file", archive.extractfile(member).read() if member.isreg() else b"", member.mtime, {}])
exec(body, {"m": m, "pkginfo": lambda: next(x for x in m if x[0] == ".PKGINFO")})
buffer = io.BytesIO()
fmt = tarfile.PAX_FORMAT if any("pax" in x[4] for x in m) else tarfile.GNU_FORMAT
with tarfile.open(fileobj=buffer, mode="w", format=fmt) as archive:
	for name, kind, content, mtime, attrs in m:
		info = tarfile.TarInfo(name)
		info.mtime = mtime
		if kind == "dir":
			info.type, info.mode = tarfile.DIRTYPE, 0o755
		elif kind == "link":
			info.type, info.linkname, info.mode = tarfile.SYMTYPE, content.decode(), 0o777
		elif kind == "hard":
			info.type, info.linkname, info.mode = tarfile.LNKTYPE, content.decode(), 0o644
		elif kind == "fifo":
			info.type, info.mode = tarfile.FIFOTYPE, 0o644
		else:
			info.size, info.mode = len(content), 0o644
		for key, value in attrs.items():
			if key == "pax":
				info.pax_headers = value
			else:
				setattr(info, key, value)
		if kind == "file":
			archive.addfile(info, io.BytesIO(content))
		else:
			archive.addfile(info)
subprocess.run(["zstd", "-q", "-19", "-T1", "-f", "-o", out], input=buffer.getvalue(), check=True)
PY
}
bad() { # <label> <expected message> <python>
	rm -rf "$WORK/bad"
	remake "$WORK/bad" "$3"
	check "$1" "1" "$(rc_of judge "$WORK/bad/${NAME:-$F}")"
	check "and says why" "1" "$(says "$2")"
	if ! grep -q -- "$2" "$WORK/last.out"; then sed 's/^/        said: /' "$WORK/last.out" | head -3; fi
}
pk() { echo "p = pkginfo(); p[2] = p[2].decode().replace($1).encode()"; }

check "a package rewritten with no change is the same as the good one in what it says" "0" "$(rm -rf "$WORK/bad"; remake "$WORK/bad" 'pass'; rc_of judge "$WORK/bad/$F")"
echo "-- the file"
NAME="glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst.x" bad "another name than the one derived from the epoch" "the only name accepted" 'pass'
NAME="evil-1.0.1700000000-1-any.pkg.tar.zst" bad "a name that is another package" "the only name accepted" 'pass'
NAME="glyndor-keyring-1.0.1700000001-1-any.pkg.tar.zst" bad "the name of another epoch" "the only name accepted" 'pass'
rm -rf "$WORK/ln"; mkdir -p "$WORK/ln"; ln -s "$GOOD" "$WORK/ln/$F"
check "a symbolic link with the right name" "1" "$(rc_of judge "$WORK/ln/$F")"
check "and says it is not a regular file" "1" "$(says 'regular file with one link')"
rm -rf "$WORK/hl"; mkdir -p "$WORK/hl"; cp "$GOOD" "$WORK/hl/$F"; ln "$WORK/hl/$F" "$WORK/hl/second"
check "a file with a second hard link" "1" "$(rc_of judge "$WORK/hl/$F")"
check "a file that is not there" "1" "$(rc_of judge "$WORK/none/$F")"
printf 'not zstd' > "$WORK/hl/plain"; mkdir -p "$WORK/nz"; cp "$WORK/hl/plain" "$WORK/nz/$F"
check "a file that is not a package" "1" "$(rc_of judge "$WORK/nz/$F")"
check "and the readers say so" "1" "$(says 'readers of the admission refused')"
check "an epoch that is not a number" "2" "$(rc_of judge "$GOOD" soon)"
check "a key file that is not a key" "1" "$(printf 'not a key' > "$WORK/notkey"; rc_of judge "$GOOD" "$EPOCH" "$WORK/notkey")"
check "a key file with two keys" "1" "$(cat "$KEY" "$WORK/other/pub.asc" > "$WORK/two.asc"; rc_of judge "$GOOD" "$EPOCH" "$WORK/two.asc")"
check "a key file that is not the key the package carries" "1" "$(rc_of judge "$GOOD" "$EPOCH" "$WORK/other/pub.asc")"
check "and says that the trust file does not name it" "1" "$(says 'does not name exactly the fingerprint')"

echo "-- the members"
bad "an extra file" "not the fixed list" 'm.append(["etc/evil", "file", b"x", 1700000000, {}])'
bad "an extra file in the folder of the keyring" "not the fixed list" 'm.append(["usr/share/pacman/keyrings/extra", "file", b"x", 1700000000, {}])'
bad "a member missing" "not the fixed list" 'm[:] = [x for x in m if x[0] != ".INSTALL"]'
bad "the members in another order" "readers of the admission refused\|not the fixed list" 'm.reverse()'
bad "a member that is a symbolic link" "neither a regular file" 'm[-1] = [m[-1][0], "link", b"/etc/shadow", 0, {}]'
bad "a folder in place of a file" "keyring file does not hold" 'm[-1][1] = "dir"'

echo "-- .PKGINFO"
bad "another package name" "fixed" "$(pk "'pkgname = glyndor-keyring', 'pkgname = glyndor-keyringx'")"
bad "another version inside" "fixed" "$(pk "'-1\n', '-2\n'")"
bad "a conflicts that no one asked for" "fixed" "$(pk "'depend = pacman\n', 'depend = pacman\nconflict = linux\n'")"
bad "a replaces" "fixed" "$(pk "'depend = pacman\n', 'depend = pacman\nreplaces = linux\n'")"
bad "a provides" "fixed" "$(pk "'depend = pacman\n', 'depend = pacman\nprovides = glibc\n'")"
bad "a second dependency" "fixed" "$(pk "'depend = pacman\n', 'depend = pacman\ndepend = bash\n'")"
bad "another dependency" "fixed" "$(pk "'depend = pacman', 'depend = bash'")"
bad "another packager" "fixed" "$(pk "'noreply@glyndor.net', 'someone@example.org'")"
bad "another url" "fixed" "$(pk "'https://pacman.glyndor.net', 'https://evil.example.org'")"
bad "another build date" "fixed" "$(pk "'builddate = 1700000000', 'builddate = 1700000009'")"
bad "another architecture" "fixed" "$(pk "'arch = any', 'arch = x86_64'")"
bad "another license" "fixed" "$(pk "'license = MIT', 'license = GPL'")"
bad "a size that is not a number" "no size, or one that is not a number" "$(pk "'size = ', 'size = x'")"
bad "no size" "no size" "$(pk "'size = ', '# size = '")"
bad "a backup entry (a file pacman would keep across upgrades)" "fixed\|readers of the admission refused" "$(pk "'depend = pacman\n', 'depend = pacman\nbackup = etc/x\n'")"

echo "-- the metadata of every member is the one build-keyring.sh writes"
bad "a file with the setuid bit" "has mode" "m[-1][4]['mode'] = 0o4755"
bad "a file that anyone can write" "has mode" "m[-1][4]['mode'] = 0o666"
bad "a file that is executable" "has mode" "m[-1][4]['mode'] = 0o755"
bad "a folder with another mode" "has mode" "m[2][4]['mode'] = 0o700"
bad "a file of another user" "owner other than" "m[-1][4]['uid'] = 1000"
bad "a file of another group" "owner other than" "m[-1][4]['gid'] = 1000"
bad "a file with an owner name" "owner other than" "m[-1][4]['uname'] = 'root'"
bad "a file with a group name" "owner other than" "m[-1][4]['gname'] = 'root'"
bad "a file with another time" "has the time" "m[-1][3] = 1700000001"
bad "a folder with another time" "has the time" "m[2][3] = 0"
bad "a file with an extended header (an xattr, for one)" "extended header" "m[-1][4]['pax'] = {'SCHILY.xattr.security.capability': 'x'}"
bad "a hard link in place of a file" "neither a regular file" "m[-1] = [m[-1][0], 'hard', b'.PKGINFO', 1700000000, {}]"
bad "a fifo in place of a file" "not a file, folder or link\\|neither a regular file" "m[-1] = [m[-1][0], 'fifo', b'', 1700000000, {}]"
bad "a symbolic link in place of a folder" "neither a regular file" "m[2] = [m[2][0], 'link', b'/', 1700000000, {}]"
check "a package whose tar stream differs only in its padding (two more zero blocks)" "1" "$(rm -rf "$WORK/bad"; mkdir -p "$WORK/bad"; python3 -I - "$GOOD" "$WORK/bad/$F" <<'PY' && rc_of judge "$WORK/bad/$F"
import subprocess, sys
data = subprocess.run(["zstd", "-dc", "-q", sys.argv[1]], stdout=subprocess.PIPE, check=True).stdout
subprocess.run(["zstd", "-q", "-19", "-T1", "-f", "-o", sys.argv[2]], input=data + bytes(1024), check=True)
PY
)"
check "and says that it is not the tar stream that is rebuilt" "1" "$(says 'byte for byte\|zero blocks\|not the fixed list')"

echo "-- the files"
bad "an .INSTALL with another line" ".INSTALL is not the fixed script" 'x = next(i for i in m if i[0] == ".INSTALL"); x[2] = x[2] + b"rm -rf /\n"'
bad "an .INSTALL that is empty" ".INSTALL is not the fixed script" 'x = next(i for i in m if i[0] == ".INSTALL"); x[2] = b""'
bad "a revocation list that is not empty" "revocation list is not empty" 'x = next(i for i in m if i[0].endswith("glyndor-revoked")); x[2] = b"0EE5C891235BE1CAD2E0ABA477E416B24362E256\n"'
OTHER="$(cat "$WORK/other/fpr")"
bad "a trust file that names another key" "trust file does not name" "x = next(i for i in m if i[0].endswith('glyndor-trusted')); x[2] = b'$OTHER:4:\n'"
bad "a trust file with a second key" "trust file does not name" "x = next(i for i in m if i[0].endswith('glyndor-trusted')); x[2] = x[2] + b'$OTHER:4:\n'"
bad "a trust file with another level of trust" "trust file does not name" "x = next(i for i in m if i[0].endswith('glyndor-trusted')); x[2] = x[2].replace(b':4:', b':5:')"
bad "a trust file with no line feed" "trust file does not name" "x = next(i for i in m if i[0].endswith('glyndor-trusted')); x[2] = x[2].rstrip(b'\n')"
OTHERPUB="$(gpg --batch --dearmor < "$WORK/other/pub.asc" | base64 -w0)"
bad "a keyring file with another key" "keyring file does not hold" "import base64; x = next(i for i in m if i[0].endswith('glyndor.gpg')); x[2] = base64.b64decode('$OTHERPUB')"
BOTH="$( { gpg --batch --dearmor < "$KEY"; gpg --batch --dearmor < "$WORK/other/pub.asc"; } | base64 -w0)"
bad "a keyring file with the key and a second one" "keyring file does not hold" "import base64; x = next(i for i in m if i[0].endswith('glyndor.gpg')); x[2] = base64.b64decode('$BOTH')"
SECRETKEY="$(gpg --batch --dearmor < "$WORK/third/secret.asc" | base64 -w0)"
bad "a keyring file that holds a secret key" "secret key\|keyring file does not hold" "import base64; x = next(i for i in m if i[0].endswith('glyndor.gpg')); x[2] = base64.b64decode('$SECRETKEY')"
bad "a keyring file that is empty" "keyring file does not hold" "x = next(i for i in m if i[0].endswith('glyndor.gpg')); x[2] = b''"
bad "a keyring file of garbage" "keyring file does not hold" "x = next(i for i in m if i[0].endswith('glyndor.gpg')); x[2] = b'garbage'"
check "an option that is missing" "2" "$(rc_of python3 -I "$TOOL" --package "$GOOD")"

finish
