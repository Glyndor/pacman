#!/usr/bin/env bash
#
# mkdb.py writes the database that the key of the repository signs, from the manifest of the admission and the .PKGINFO it
# read. Three things have to hold. It is the same bytes for the same input. Its `desc` of each package is, text for text,
# what repo-add of the pinned Arch image writes for the same package (repo-add is the cross-check, never the source). And
# pacman of that image reads it: a repository of one folder, `pacman -Sy`, then `pacman -Si` shows the fields and
# `pacman -S` installs. What is refused is each way the inputs could say more than the packages do.
#
# Requires: docker or podman, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
MKDB="$HERE/scripts/metadata/mkdb.py"
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
says() { if grep -q -F -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }
PK="$WORK/pk"
mkdir -p "$PK"
python3 -I "$FIXTURES/mkpkg.py" "$PK/alpha-1.2.3-1-x86_64.pkg.tar.zst" alpha 1.2.3-1 x86_64 --makepkg-layout --set pkgbase=alpha \
	--append depend=foo --append depend=bar --append optdepend='extra: for more' --append provides=baz=1 --append conflict=old --append replaces=old --append license=MIT
python3 -I "$FIXTURES/mkpkg.py" "$PK/beta-0.1.0-1-any.pkg.tar.zst" beta 0.1.0-1 any --append group=tools --append makedepend=gcc
python3 -I "$FIXTURES/mkpkg.py" "$PK/gamma-2.0.0+r3-1-x86_64.pkg.tar.zst" gamma 2.0.0+r3-1 x86_64
python3 -I "$FIXTURES/pkginfo.py" "$PK"/*.pkg.tar.zst > "$WORK/pkginfo.json"
: > "$WORK/manifest.tsv"
for f in "$PK"/*.pkg.tar.zst; do
	b="$(basename "$f")"
	rest="${b%.pkg.tar.zst}"
	arch="${rest##*-}"
	rest="${rest%-"$arch"}"
	ver="${rest#*-[0-9]}"
	name="${b%%-[0-9]*}"
	ver="${rest#"$name"-}"
	printf 'r\t%s\t%s\t%s\t%s\t%s\t%s\tno\n' "$name" "$ver" "$arch" "$b" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" >> "$WORK/manifest.tsv"
done
gen() { python3 -I "$MKDB" --manifest "$WORK/manifest.tsv" --pkginfo "${INFO:-$WORK/pkginfo.json}" --packages "${PKGS:-$PK}" --out "$1"; }

check "the database is written" "0" "$(rc_of gen "$WORK/db1.tar.zst")"
check "the same input gives the same bytes" "0" "$(rm -f "$WORK/db2.tar.zst"; gen "$WORK/db2.tar.zst" > /dev/null; cmp "$WORK/db1.tar.zst" "$WORK/db2.tar.zst" > /dev/null 2>&1; echo $?)"
check "even with another clock and another order of the manifest" "0" "$(sleep 2; sort -r "$WORK/manifest.tsv" > "$WORK/manifest-r.tsv"; rm -f "$WORK/db3.tar.zst"; python3 -I "$MKDB" --manifest "$WORK/manifest-r.tsv" --pkginfo "$WORK/pkginfo.json" --packages "$PK" --out "$WORK/db3.tar.zst" > /dev/null; cmp "$WORK/db1.tar.zst" "$WORK/db3.tar.zst" > /dev/null 2>&1; echo $?)"
check "the entries are sorted by name, each a folder and its desc, with nothing else" "alpha-1.2.3-1/
alpha-1.2.3-1/desc
beta-0.1.0-1/
beta-0.1.0-1/desc
gamma-2.0.0+r3-1/
gamma-2.0.0+r3-1/desc" "$(zstd -dc -q "$WORK/db1.tar.zst" | tar -t)"
check "every entry has time 0 and owner root, and no extension header" "0" "$(zstd -dc -q "$WORK/db1.tar.zst" | tar -tv --full-time | grep -v -c -e 'root/root' -e '1970-01-01 00:00:00' || true)"
check "the strict reader of the served database reads it" "0" "$(rc_of python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$WORK/db1.tar.zst")"
check "and lists the three packages" "alpha beta gamma" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$WORK/db1.tar.zst" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

echo "-- the cross-check: the desc of repo-add, and pacman reading the database"
mkdir -p "$WORK/c/repo"
cp "$PK"/*.pkg.tar.zst "$WORK/c/repo/"
cp "$WORK/db1.tar.zst" "$WORK/c/repo/glyndor.db"
mkdir -p "$WORK/c/ref"
cp "$PK"/*.pkg.tar.zst "$WORK/c/ref/"
chmod -R a+rwX "$WORK/c"
cat > "$WORK/c/run.sh" <<'SH'
set -e
cd /work/ref
repo-add -q glyndor.db.tar.zst *.pkg.tar.zst
cat > /tmp/pacman.conf <<CONF
[options]
Architecture = x86_64
DBPath = /tmp/db
CacheDir = /tmp/cache
LogFile = /tmp/pacman.log
GPGDir = /etc/pacman.d/gnupg
[glyndor]
SigLevel = Never
Server = file:///work/repo
CONF
mkdir -p /tmp/db /tmp/cache
pacman --config /tmp/pacman.conf -Sy > /work/sy.log 2>&1
pacman --config /tmp/pacman.conf -Si alpha > /work/si-alpha.log 2>&1
pacman --config /tmp/pacman.conf -Si beta > /work/si-beta.log 2>&1
pacman --config /tmp/pacman.conf -Sl glyndor > /work/sl.log 2>&1
SH
chmod 644 "$WORK/c/run.sh"
image="$(bash "$HERE/scripts/assemble/arch-image.sh")"
engine=docker
if ! { command -v docker > /dev/null && timeout 60 docker info > /dev/null 2>&1; }; then engine=podman; fi
check "pacman of the image reads the database and repo-add writes its own" "0" "$(rc_of "$engine" run --rm --network none --volume "$WORK/c:/work:rw" "$image" bash /work/run.sh)"
check "pacman synchronised the repository from the database written here" "1" "$(grep -c 'glyndor' "$WORK/c/sy.log")"
check "-Si shows the version of alpha" "1" "$(grep -c '^Version *: 1.2.3-1$' "$WORK/c/si-alpha.log")"
check "-Si shows what alpha provides, replaces, conflicts with and depends on" "1" "$(grep -c -E '^(Provides|Replaces|Conflicts With|Depends On) ' "$WORK/c/si-alpha.log" | grep -c '^4$')"
check "-Si shows the group of beta" "1" "$(grep -c '^Groups *: tools$' "$WORK/c/si-beta.log")"
check "-Sl lists the three" "3" "$(grep -c '^glyndor ' "$WORK/c/sl.log")"
for name in alpha-1.2.3-1 beta-0.1.0-1 gamma-2.0.0+r3-1; do
	ref="$(tar --zstd -xOf "$WORK/c/ref/glyndor.db.tar.zst" "$name/desc")"
	got="$(zstd -dc -q "$WORK/db1.tar.zst" | tar -xO "$name/desc")"
	check "the desc of $name is, text for text, the one repo-add writes" "$ref" "$got"
done

echo "-- what the inputs may not say"
mutate() { # <python on `info`>: a copy of the .PKGINFO data with that change, and the database that results
	python3 -I - "$WORK/pkginfo.json" "$WORK/bad.json" "$1" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
exec(sys.argv[3], {"info": info})
json.dump(info, open(sys.argv[2], "w"))
PY
	rm -f "$WORK/bad.tar.zst"
	INFO="$WORK/bad.json" rc_of gen "$WORK/bad.tar.zst"
}
A='info["alpha-1.2.3-1-x86_64.pkg.tar.zst"]'
check "a value with a line feed (it would write a second line of the desc)" "1" "$(mutate "${A}[\"depend\"] = [\"foo\\nreplaces\"]")"
check "and the refusal says what it is" "1" "$(says 'control character')"
check "an empty value" "1" "$(mutate "${A}[\"depend\"] = [\"\"]")"
check "no value at all for a key" "1" "$(mutate "${A}[\"depend\"] = []")"
check "a key the database does not carry (backup is read and not written, md5sum is neither)" "1" "$(mutate "${A}[\"md5sum\"] = [\"00\"]")"
check "and says which" "1" "$(says 'does not carry: md5sum')"
check "a value that is not text" "1" "$(mutate "${A}[\"depend\"] = [5]")"
check "a name that is not the manifest's" "1" "$(mutate "${A}[\"pkgname\"] = [\"evil\"]")"
check "a version that is not the manifest's" "1" "$(mutate "${A}[\"pkgver\"] = [\"9.9.9-1\"]")"
check "an architecture that is not the manifest's" "1" "$(mutate "${A}[\"arch\"] = [\"any\"]")"
check "no .PKGINFO for a package of the manifest" "1" "$(mutate 'info.pop("beta-0.1.0-1-any.pkg.tar.zst")')"
check "a .PKGINFO that is not an object" "1" "$(mutate "info[\"beta-0.1.0-1-any.pkg.tar.zst\"] = 5")"
check "a .PKGINFO file that is not JSON" "1" "$(printf x > "$WORK/notjson"; rm -f "$WORK/bad.tar.zst"; INFO="$WORK/notjson" rc_of gen "$WORK/bad.tar.zst")"
check "an extra key of .PKGINFO that is read and not written is accepted (xdata, backup)" "0" "$(mutate "${A}[\"xdata\"] = [\"pkgtype=pkg\"]; ${A}[\"backup\"] = [\"etc/x\"]")"
rm -rf "$WORK/p2"; cp -r "$PK" "$WORK/p2"
check "a package that is not the admitted bytes" "1" "$(printf x >> "$WORK/p2/beta-0.1.0-1-any.pkg.tar.zst"; rm -f "$WORK/bad.tar.zst"; PKGS="$WORK/p2" rc_of gen "$WORK/bad.tar.zst")"
rm -rf "$WORK/p2"; cp -r "$PK" "$WORK/p2"
check "a package that is not in the manifest" "1" "$(cp "$PK/beta-0.1.0-1-any.pkg.tar.zst" "$WORK/p2/extra-1.0.0-1-any.pkg.tar.zst"; rm -f "$WORK/bad.tar.zst"; PKGS="$WORK/p2" rc_of gen "$WORK/bad.tar.zst")"
rm -rf "$WORK/p2"; cp -r "$PK" "$WORK/p2"
check "a package that is a symbolic link" "1" "$(rm "$WORK/p2/beta-0.1.0-1-any.pkg.tar.zst"; ln -s "$PK/beta-0.1.0-1-any.pkg.tar.zst" "$WORK/p2/beta-0.1.0-1-any.pkg.tar.zst"; rm -f "$WORK/bad.tar.zst"; PKGS="$WORK/p2" rc_of gen "$WORK/bad.tar.zst")"
check "a manifest that is empty" "1" "$(: > "$WORK/empty.tsv"; rm -f "$WORK/bad.tar.zst"; rc_of python3 -I "$MKDB" --manifest "$WORK/empty.tsv" --pkginfo "$WORK/pkginfo.json" --packages "$PK" --out "$WORK/bad.tar.zst")"
check "a manifest that lists a package twice" "1" "$(cat "$WORK/manifest.tsv" "$WORK/manifest.tsv" > "$WORK/twice.tsv"; rm -f "$WORK/bad.tar.zst"; rc_of python3 -I "$MKDB" --manifest "$WORK/twice.tsv" --pkginfo "$WORK/pkginfo.json" --packages "$PK" --out "$WORK/bad.tar.zst")"
check "a manifest row with a file name that is not the one of its fields" "1" "$(sed 's/gamma-2.0.0+r3-1-x86_64.pkg.tar.zst/delta-2.0.0+r3-1-x86_64.pkg.tar.zst/' "$WORK/manifest.tsv" > "$WORK/renamed.tsv"; rm -f "$WORK/bad.tar.zst"; rc_of python3 -I "$MKDB" --manifest "$WORK/renamed.tsv" --pkginfo "$WORK/pkginfo.json" --packages "$PK" --out "$WORK/bad.tar.zst")"
check "an output that already exists is not overwritten" "1" "$(rc_of gen "$WORK/db1.tar.zst")"
check "an option missing" "2" "$(rc_of python3 -I "$MKDB" --manifest "$WORK/manifest.tsv")"

finish
