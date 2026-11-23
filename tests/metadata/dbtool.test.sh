#!/usr/bin/env bash
#
# dbtool.py: what a SERVED database says, read as hostile input, and the state a signature will cover.
# pacman has no expiry or counter in its database, so the state is the only thing that says a repository
# is not frozen or turned back: it has to be current, strictly newer than the one before, about exactly the
# database that is served, and it keeps a replaced package listed until the metadata that names it cannot be
# valid any more. Each case below breaks one of those on purpose.
#
# Requires: python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
TOOL="$HERE/scripts/metadata/dbtool.py"
tool() { python3 -I "$TOOL" "$@"; }
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	# a traceback is a crash and never a verdict
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
NOW="2026-11-23T06:00:00Z"

PK="$WORK/pk"
mkdir -p "$PK"
python3 -I "$FIXTURES/mkpkg.py" "$PK/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$PK/lib-0.1.0-1-any.pkg.tar.zst" lib 0.1.0-1 any
python3 -I "$FIXTURES/pkginfo.py" "$PK"/*.pkg.tar.zst > "$WORK/pkginfo.json"
write_manifest() { : > "$1"; local f b name rest arch; for f in "$PK"/*.pkg.tar.zst; do b="$(basename "$f")"; name="${b%%-[0-9]*}"; rest="${b%.pkg.tar.zst}"; arch="${rest##*-}"; rest="${rest%-"$arch"}"; printf 'r\t%s\t%s\t%s\t%s\t%s\t%s\tno\n' "$name" "${rest#"$name"-}" "$arch" "$b" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" >> "$1"; done; }
write_manifest "$WORK/m0.tsv"
python3 -I "$HERE/scripts/metadata/mkdb.py" --manifest "$WORK/m0.tsv" --pkginfo "$WORK/pkginfo.json" --packages "$PK" --out "$WORK/db.tar.zst" > /dev/null
A="acme-1.2.3-1-x86_64.pkg.tar.zst"
L="lib-0.1.0-1-any.pkg.tar.zst"
sum() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c%s "$1"; }
printf 'r\tacme\t1.2.3-1\tx86_64\t%s\t%s\t%s\tno\nr\tlib\t0.1.0-1\tany\t%s\t%s\t%s\tno\n' "$A" "$(size "$PK/$A")" "$(sum "$PK/$A")" "$L" "$(size "$PK/$L")" "$(sum "$PK/$L")" > "$WORK/manifest.tsv"

echo "-- entries"
check "a database is read: name, pkgver, file, size, sha256, architecture" \
	"acme	1.2.3-1	$A	$(size "$PK/$A")	$(sum "$PK/$A")	x86_64
lib	0.1.0-1	$L	$(size "$PK/$L")	$(sum "$PK/$L")	any" "$(tool entries "$WORK/db.tar.zst")"
make_files_db() { python3 -I - "$WORK/files.tar.zst" <<'PY'
import io, subprocess, sys, tarfile
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as archive:
	folder = tarfile.TarInfo("a-1-1"); folder.type = tarfile.DIRTYPE; archive.addfile(folder)
	body = b"%FILES%\nusr/\n"
	member = tarfile.TarInfo("a-1-1/files"); member.size = len(body); archive.addfile(member, io.BytesIO(body))
subprocess.run(["zstd", "-q", "-f", "-o", sys.argv[1]], input=buffer.getvalue(), check=True)
PY
}
make_files_db
check "a files database is not a database of this repository: a files member is refused" "1" "$(rc_of tool entries "$WORK/files.tar.zst")"
check "and says that the member is not <package>/desc" "1" "$(says 'not <package>/desc')"
make_db() { # <out> <python statements that fill `archive`, with add(name, text)>
	python3 -I - "$1" "$2" <<'PY'
import io, subprocess, sys, tarfile
out, body = sys.argv[1], sys.argv[2]
buffer = io.BytesIO()
archive = tarfile.open(fileobj=buffer, mode="w")
def add(name, text):
	member = tarfile.TarInfo(name)
	member.size = len(text)
	archive.addfile(member, io.BytesIO(text.encode()))
def desc(name="a", ver="1-1", file=None, csize="3", sha="0" * 64, arch="x86_64", skip=()):
	file = file or f"{name}-{ver}-{arch}.pkg.tar.zst"
	fields = {"FILENAME": file, "NAME": name, "VERSION": ver, "CSIZE": csize, "SHA256SUM": sha, "ARCH": arch}
	return "".join(f"%{k}%\n{v}\n\n" for k, v in fields.items() if k not in skip)
exec(body)
archive.close()
subprocess.run(["zstd", "-q", "-f", "-o", out], input=buffer.getvalue(), check=True)
PY
}
bad_db() { make_db "$WORK/bad.tar.zst" "$1"; rc_of tool entries "$WORK/bad.tar.zst"; }
check "a well formed database from the helper is read" "0" "$(bad_db 'add("a-1-1/desc", desc())')"
check "a member that climbs out is refused" "1" "$(bad_db 'add("../a-1-1/desc", desc())')"
check "a member that is not desc is refused" "1" "$(bad_db 'add("a-1-1/script", desc())')"
check "a files member next to a good desc in the database itself is refused" "1" "$(bad_db 'add("a-1-1/desc", desc()); add("a-1-1/files", "%FILES%\nusr/bin/x\n")')"
check "and so is a files member of another package" "1" "$(bad_db 'add("a-1-1/desc", desc()); add("b-1-1/files", "%FILES%\n")')"
for key in MD5SUM PGPSIG XDATA FILES NOPE; do
	check "a desc with the key $key, which the repository does not carry, is refused" "1" "$(bad_db "add('a-1-1/desc', desc() + '%$key%\nx\n\n')")"
	check "and names it" "1" "$(says "carry: $key")"
done
check "text before the first key of a desc is refused" "1" "$(bad_db 'add("a-1-1/desc", "stray\n" + desc())')"
check "a package listed twice is refused" "1" "$(bad_db 'add("a-1-1/desc", desc()); add("a-2-1/desc", desc(ver="2-1"))')"
check "and says that it is listed twice or does not match" "1" "$(says 'listed twice')"
check "an entry whose folder is not its name and version is refused" "1" "$(bad_db 'add("b-1-1/desc", desc())')"
check "a file name that is not name-version-arch is refused" "1" "$(bad_db 'add("a-1-1/desc", desc(file="other-1-1-x86_64.pkg.tar.zst"))')"
check "an architecture the repository does not carry is refused" "1" "$(bad_db 'add("a-1-1/desc", desc(arch="aarch64"))')"
check "a sha256 that is not one is refused" "1" "$(bad_db 'add("a-1-1/desc", desc(sha="xyz"))')"
check "an entry with no size is refused" "1" "$(bad_db 'add("a-1-1/desc", desc(skip=("CSIZE",)))')"
check "and names the missing field" "1" "$(says 'no CSIZE')"
check "a field set twice is refused" "1" "$(bad_db 'add("a-1-1/desc", desc() + "%NAME%\nb\n\n")')"
printf 'not a database' > "$WORK/junk"
check "bytes that are not a database are refused" "1" "$(rc_of tool entries "$WORK/junk")"
zstd -dc -q "$WORK/db.tar.zst" | gzip -c > "$WORK/db.gz"
check "a database in another compression is refused before a decompressor sees it" "1" "$(rc_of tool entries "$WORK/db.gz")"
check "and says that it lacks the zstd magic" "1" "$(says 'zstd magic')"

echo "-- the end of the archive and the grammar of a desc (what libalpm would read and this reader must not miss)"
raw_db() { # <out> <python that builds `blob` (the tar bytes, with `good` available)>
	python3 -I - "$1" "$2" <<'PY'
import io, subprocess, sys, tarfile
out, body = sys.argv[1], sys.argv[2]
def tar_of(members, pad=True):
	buffer = io.BytesIO()
	with tarfile.open(fileobj=buffer, mode="w") as archive:
		for name, text in members:
			info = tarfile.TarInfo(name)
			info.size = len(text)
			archive.addfile(info, io.BytesIO(text.encode()))
	return buffer.getvalue()
def desc(extra="", body=None):
	return body if body is not None else "".join(f"%{k}%\n{v}\n\n" for k, v in {"FILENAME": "a-1.0.0-1-x86_64.pkg.tar.zst", "NAME": "a", "VERSION": "1.0.0-1", "CSIZE": "3", "SHA256SUM": "0" * 64, "ARCH": "x86_64"}.items()) + extra
good = tar_of([("a-1.0.0-1/desc", desc())])
scope = {"tar_of": tar_of, "desc": desc, "good": good}
exec(body, scope)
subprocess.run(["zstd", "-q", "-f", "-o", out], input=scope["blob"], check=True)
PY
	rc_of tool entries "$1"
}
check "a database that is well formed is read" "0" "$(raw_db "$WORK/r.zst" 'blob = good')"
check "a second archive hidden after the end marks is refused" "1" "$(raw_db "$WORK/r.zst" 'blob = good + tar_of([("b-1.0.0-1/desc", desc())])')"
check "and says that data follows the end of the archive" "1" "$(says 'after the end of the archive')"
check "a byte after the end marks is refused" "1" "$(raw_db "$WORK/r.zst" 'blob = good.rstrip(bytes(1)) + bytes(10240) + b"x"')"
check "an archive with no end marks is refused" "1" "$(raw_db "$WORK/r.zst" 'blob = good[:-10240]')"
check "a key inside a section that is not closed (no blank line at the end)" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc(body="%FILENAME%\na-1.0.0-1-x86_64.pkg.tar.zst\n%NAME%\na\n\n"))])')"
check "a value after the blank line, with no key" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc("stray\n\n"))])')"
check "an empty section (key and blank line, no value)" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc("%GROUPS%\n\n"))])')"
check "and says the key has no value" "1" "$(says 'with no value')"
check "two blank lines in a row" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc() + "\n")])')"
check "a desc that does not end with the blank line" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc().rstrip("\n") + "\n")])')"
check "a NUL byte in a value" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc("%GROUPS%\nx\0y\n\n"))])')"
check "a carriage return in a value" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc("%GROUPS%\nx\ry\n\n"))])')"
check "a key with lower case letters" "1" "$(raw_db "$WORK/r.zst" 'blob = tar_of([("a-1.0.0-1/desc", desc("%groups%\nx\n\n"))])')"
check "a global pax header" "1" "$(raw_db "$WORK/r.zst" 'import tarfile as t\nbuf = io.BytesIO()\nwith t.open(fileobj=buf, mode="w", format=t.PAX_FORMAT, pax_headers={"comment": "x"}) as a:\n\ti = t.TarInfo("a-1.0.0-1/desc"); t_ = desc(); i.size = len(t_); a.addfile(i, io.BytesIO(t_.encode()))\nblob = buf.getvalue()')"
check "a long name header" "1" "$(raw_db "$WORK/r.zst" 'import tarfile as t\nbuf = io.BytesIO()\nwith t.open(fileobj=buf, mode="w", format=t.GNU_FORMAT) as a:\n\ti = t.TarInfo("a-1.0.0-1/" + "d" * 120); t_ = desc(); i.size = len(t_); a.addfile(i, io.BytesIO(t_.encode()))\nblob = buf.getvalue()')"

echo "-- what a hostile database costs"
python3 -I - "$WORK/huge.db.tar.zst" <<'PY'
import subprocess, sys, tarfile, io
buffer = io.BytesIO()
info = tarfile.TarInfo("PaxHeaders/x")
info.type, info.size = b"x", 2 * 1024**3
buffer.write(info.tobuf(tarfile.GNU_FORMAT, "utf-8", "surrogateescape"))
subprocess.run(["zstd", "-q", "-f", "-o", sys.argv[1]], input=buffer.getvalue(), check=True)
PY
check "a pax header that claims two gigabytes is refused before it is read" "1" "$(rc_of tool entries "$WORK/huge.db.tar.zst")"
check "and says that it is an extended header" "1" "$(says 'extended (pax) header')"
python3 -I - "$WORK/bomb.db.tar.zst" <<'PY'
import io, subprocess, sys, tarfile
class Zeros(io.RawIOBase):
	def __init__(self, n): self.n = n
	def readable(self): return True
	def readinto(self, b):
		take = min(len(b), self.n)
		b[:take] = bytes(take)
		self.n -= take
		return take
proc = subprocess.Popen(["zstd", "-q", "-1", "-f", "-o", sys.argv[1]], stdin=subprocess.PIPE)
with tarfile.open(fileobj=proc.stdin, mode="w|") as archive:
	folder = tarfile.TarInfo("a-1-1"); folder.type = tarfile.DIRTYPE; archive.addfile(folder)
	big = tarfile.TarInfo("a-1-1/desc")
	big.size = 200 * 1024 * 1024
	archive.addfile(big, Zeros(big.size))
proc.stdin.close()
proc.wait()
PY
check "a desc of 200 MiB is refused for its size, not read" "1" "$(rc_of tool entries "$WORK/bomb.db.tar.zst")"
rm -f "$WORK/bomb.db.tar.zst" "$WORK/huge.db.tar.zst"

echo "-- the state"
python3 -I "$FIXTURES/mkpkg.py" "$PK/zed-1.0.0-1-any.pkg.tar.zst" zed 1.0.0-1 any
python3 -I "$FIXTURES/pkginfo.py" "$PK"/*.pkg.tar.zst > "$WORK/pkginfo-extra.json"
write_manifest "$WORK/m-extra.tsv"
python3 -I "$HERE/scripts/metadata/mkdb.py" --manifest "$WORK/m-extra.tsv" --pkginfo "$WORK/pkginfo-extra.json" --packages "$PK" --out "$WORK/db-extra.tar.zst" > /dev/null
rm "$PK/zed-1.0.0-1-any.pkg.tar.zst"
make_state() { # <name> <previous or -> <now> <served tsv> [db]
	rm -f "$WORK/$1"
	tool state-make --previous "$2" --db "${5:-$WORK/db.tar.zst}" --now "$3" --served "$4" --out "$WORK/$1"
}
: > "$WORK/served-empty.tsv"
check "a first state is made" "0" "$(rc_of make_state state1 - "$NOW" "$WORK/served-empty.tsv")"
check "it is sequence 1" "1" "$(tool state-get "$WORK/state1" sequence)"
check "it says when it was generated" "$NOW" "$(tool state-get "$WORK/state1" generated)"
check "it is valid for 14 days" "2026-12-07T06:00:00Z" "$(tool state-get "$WORK/state1" valid-until)"
check "it names the database it is about" "$(sum "$WORK/db.tar.zst")" "$(tool state-get "$WORK/state1" db-sha256)"
check "it counts the packages" "2" "$(tool state-get "$WORK/state1" packages)"
check "and retires nothing" "" "$(tool state-get "$WORK/state1" retired)"
check "a state that was just made is valid" "0" "$(rc_of tool state-check "$WORK/state1" --db "$WORK/db.tar.zst" --now "$NOW")"
check "it is valid until the last second before it expires" "0" "$(rc_of tool state-check "$WORK/state1" --db "$WORK/db.tar.zst" --now 2026-12-07T05:59:59Z)"
check "and not at the second it expires" "1" "$(rc_of tool state-check "$WORK/state1" --db "$WORK/db.tar.zst" --now 2026-12-07T06:00:00Z)"
check "and says it expired" "1" "$(says 'expired')"
check "a state from the future (more than five minutes) is refused" "1" "$(rc_of tool state-check "$WORK/state1" --db "$WORK/db.tar.zst" --now 2026-11-23T05:50:00Z)"
check "and says so" "1" "$(says 'in the future')"
check "a state a minute ahead of the clock is tolerated" "0" "$(rc_of tool state-check "$WORK/state1" --db "$WORK/db.tar.zst" --now 2026-11-23T05:59:00Z)"
check "a state about another database is refused" "1" "$(rc_of tool state-check "$WORK/state1" --db "$WORK/db-extra.tar.zst" --now "$NOW")"
check "and says so" "1" "$(says 'another database')"
check "a state whose count disagrees with the database is refused" "1" \
	"$(sed 's/^packages: 2/packages: 3/' "$WORK/state1" > "$WORK/state-count"; rc_of tool state-check "$WORK/state-count" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state valid for another time than 14 days is refused" "1" \
	"$(sed 's/^valid-until: .*/valid-until: 2027-11-23T06:00:00Z/' "$WORK/state1" > "$WORK/state-long"; rc_of tool state-check "$WORK/state-long" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state with a key it does not know is refused" "1" "$(sed '$a extra: 1' "$WORK/state1" > "$WORK/state-extra"; rc_of tool state-check "$WORK/state-extra" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state with the keys in another order is refused" "1" "$(awk 'NR == 2 { held = $0; next } NR == 3 { print; print held; next } { print }' "$WORK/state1" > "$WORK/state-order"; rc_of tool state-check "$WORK/state-order" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state with a key set twice is refused" "1" "$(sed '4p' "$WORK/state1" > "$WORK/state-twice"; rc_of tool state-check "$WORK/state-twice" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state with a missing key is refused" "1" "$(sed '4d' "$WORK/state1" > "$WORK/state-miss"; rc_of tool state-check "$WORK/state-miss" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state with a byte that is not ASCII is refused" "1" "$(printf '\xc3\xa9\n' >> "$WORK/state1"; cp "$WORK/state1" "$WORK/state-byte"; sed -i '$d' "$WORK/state1"; rc_of tool state-check "$WORK/state-byte" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state for another repository is refused" "1" "$(sed 's/^repository: glyndor/repository: other/' "$WORK/state1" > "$WORK/state-repo"; rc_of tool state-check "$WORK/state-repo" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a time that is not UTC in the form of the state is refused" "1" "$(sed 's/^generated: .*/generated: 2026-11-23 06:00:00/' "$WORK/state1" > "$WORK/state-time"; rc_of tool state-check "$WORK/state-time" --db "$WORK/db.tar.zst" --now "$NOW")"
check "a state file that is not there is refused" "1" "$(rc_of tool state-check "$WORK/none" --db "$WORK/db.tar.zst" --now "$NOW")"
check "state-get of a key that is not there is refused" "1" "$(rc_of tool state-get "$WORK/state1" nothing)"

echo "-- the sequence, and what is retired"
SERVED="$WORK/served.tsv"
printf 'acme\t1.2.2-1\tabc\tacme-1.2.2-1-x86_64.pkg.tar.zst\nlib\t0.1.0-1\tdef\t%s\n' "$L" > "$SERVED"
check "the next state is made from the one served" "0" "$(rc_of make_state state2 "$WORK/state1" 2026-11-24T06:00:00Z "$SERVED")"
check "its sequence is the next one" "2" "$(tool state-get "$WORK/state2" sequence)"
check "a package that is no longer in the database is retired, for 15 days" "acme-1.2.2-1-x86_64.pkg.tar.zst 2026-11-24T06:00:00Z 2026-12-09T06:00:00Z" "$(tool state-get "$WORK/state2" retired)"
check "a package that is still in the database is not retired" "0" "$(tool state-get "$WORK/state2" retired | grep -c 'lib-0.1')"
check "a state older than the one served is refused" "1" "$(rc_of make_state state3 "$WORK/state2" 2026-11-23T06:00:00Z "$SERVED")"
check "and says it is before the one served" "1" "$(says 'before the one served')"
check "the same second is accepted (a rerun)" "0" "$(rc_of make_state state3 "$WORK/state2" 2026-11-24T06:00:00Z "$SERVED")"
check "its sequence still goes up" "3" "$(tool state-get "$WORK/state3" sequence)"
printf 'acme\t1.2.3-1\tabc\t%s\n' "$A" > "$WORK/served-now.tsv"
make_state state4 "$WORK/state2" 2026-11-30T06:00:00Z "$WORK/served-now.tsv"
check "a retired package is carried to the next state with its first dates" "acme-1.2.2-1-x86_64.pkg.tar.zst 2026-11-24T06:00:00Z 2026-12-09T06:00:00Z" "$(tool state-get "$WORK/state4" retired)"
make_state state5 "$WORK/state4" 2026-12-17T06:00:00Z "$WORK/served-now.tsv"
check "and is dropped a week after its delete-after date" "" "$(tool state-get "$WORK/state5" retired)"
check "a state made over an existing file is refused" "1" "$(rc_of tool state-make --previous - --db "$WORK/db.tar.zst" --now "$NOW" --served "$WORK/served-empty.tsv" --out "$WORK/state1")"
check "a previous state that is malformed is refused" "1" "$(printf 'junk\n' > "$WORK/state-junk"; rc_of make_state state6 "$WORK/state-junk" "$NOW" "$SERVED")"
check "a time that is not a time is refused" "1" "$(rc_of make_state state7 - yesterday "$WORK/served-empty.tsv")"

finish
