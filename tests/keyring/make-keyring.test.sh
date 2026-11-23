#!/usr/bin/env bash
#
# make-keyring.sh: the keyring package is built in the pinned image and joins what was admitted as one more row of the
# manifest, in a folder of its own, so that the database and the signer see it like any other package. Its version
# comes from the time of the last commit of its inputs unless one is given, and a checkout with no history stops it.
# What the container leaves is not believed: the name is derived on the host and the package is judged there, and the
# row and the data of .PKGINFO are made from that judgement. A stand-in for the container leaves hostile things in its
# folder to prove it.
#
# Requires: docker or podman, git.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/keyring/make-keyring.sh"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
: > "$WORK/manifest.tsv"
printf '{"x-1-1-any.pkg.tar.zst": {"pkgname": ["x"]}}' > "$WORK/pkginfo.json"
printf '{}' > "$WORK/pkginfo2.json"
mkdir -p "$WORK/admitted/podup"
check "the package is built and added" "0" "$(rc_of bash "$SCRIPT" --admitted "$WORK/admitted" --manifest "$WORK/manifest.tsv" --pkginfo "$WORK/pkginfo.json" --epoch 1700000000)"
F="glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst"
check "it is in a folder of its own" "yes" "$([ -f "$WORK/admitted/glyndor/$F" ] && echo yes || echo no)"
check "the manifest has one row for it, with the size and hash of that file" \
	"glyndor	glyndor-keyring	1.0.1700000000-1	any	$F	$(stat -c%s "$WORK/admitted/glyndor/$F")	$(sha256sum "$WORK/admitted/glyndor/$F" | cut -d' ' -f1)	no" "$(cat "$WORK/manifest.tsv")"
check "what the package says of itself joins what was already there" "$F x-1-1-any.pkg.tar.zst" "$(python3 -I -c 'import json,sys; print(*sorted(json.load(open(sys.argv[1]))))' "$WORK/pkginfo.json")"
check "and it says the fields the database is compared with" "1.0.1700000000-1" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["pkgver"][0])' "$WORK/pkginfo.json" "$F")"
check "a second run into the same place is refused" "2" "$(rc_of bash "$SCRIPT" --admitted "$WORK/admitted" --manifest "$WORK/manifest.tsv" --pkginfo "$WORK/pkginfo.json" --epoch 1700000000)"
check "and left the manifest as it was" "1" "$(wc -l < "$WORK/manifest.tsv")"
rm -rf "$WORK/admitted/glyndor"; : > "$WORK/manifest2.tsv"
check "with no epoch the version comes from the history of the inputs" "0" "$(rc_of bash "$SCRIPT" --admitted "$WORK/admitted" --manifest "$WORK/manifest2.tsv" --pkginfo "$WORK/pkginfo2.json")"
want="$(git -C "$HERE" log -1 --format=%ct -- keyring/glyndor-pacman-key.asc scripts/keyring/build-keyring.sh scripts/keyring/make-keyring.sh)"
check "which is the time of the last commit that changed them" "1.0.$want-1" "$(cut -f3 "$WORK/manifest2.tsv")"
rm -rf "$WORK/admitted/glyndor"
check "a manifest that is not there" "2" "$(rc_of bash "$SCRIPT" --admitted "$WORK/admitted" --manifest "$WORK/none.tsv" --pkginfo "$WORK/pkginfo.json" --epoch 1700000000)"
check "no file of .PKGINFO data is a usage error" "2" "$(rc_of bash "$SCRIPT" --admitted "$WORK/admitted" --manifest "$WORK/manifest.tsv")"
check "an option that is not known" "2" "$(rc_of bash "$SCRIPT" --nope x)"
check "no option" "2" "$(rc_of bash "$SCRIPT")"
check "an epoch that is not a time stops the build" "2" "$(: > "$WORK/m3.tsv"; rc_of bash "$SCRIPT" --admitted "$WORK/admitted" --manifest "$WORK/m3.tsv" --pkginfo "$WORK/pkginfo.json" --epoch soon)"
check "and adds nothing" "0" "$(wc -c < "$WORK/m3.tsv")"

echo "-- what a container may leave in its folder is not believed"
FK="$WORK/fake"
mkdir -p "$FK/scripts/keyring" "$FK/scripts/admit" "$FK/scripts/assemble" "$FK/keyring"
cp "$HERE/scripts/keyring/make-keyring.sh" "$HERE/scripts/keyring/check-keyring.py" "$HERE/scripts/keyring/build-keyring.sh" "$FK/scripts/keyring/"
cp "$HERE"/scripts/admit/package-reader.py "$HERE"/scripts/admit/list-package.sh "$FK/scripts/admit/"
cp "$HERE/scripts/assemble/run-in-arch.sh" "$FK/scripts/assemble/real-run-in-arch.sh"
cp "$HERE/scripts/assemble/arch-image.txt" "$FK/scripts/assemble/"
cp "$HERE/keyring/glyndor-pacman-key.asc" "$FK/keyring/"
cat > "$FK/scripts/assemble/run-in-arch.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != scripts/keyring/build-keyring.sh ]; then exec bash "$(dirname "$0")/real-run-in-arch.sh" "$@"; fi
out="$2/out"
mkdir -p "$out"
bash "$FAKE_BUILD" "$out"
STUB
FK_EPOCH=1700000000
fake_run() { # <build script body, with $1 = the out folder>: make-keyring.sh in the fake tree, a fresh manifest and data
	printf '%s\n' "$1" > "$WORK/fake-build.sh"
	rm -rf "$WORK/fadm"; mkdir -p "$WORK/fadm"
	: > "$WORK/fman.tsv"; printf '{}' > "$WORK/finfo.json"
	FAKE_BUILD="$WORK/fake-build.sh" rc_of bash "$FK/scripts/keyring/make-keyring.sh" --admitted "$WORK/fadm" --manifest "$WORK/fman.tsv" --pkginfo "$WORK/finfo.json" --epoch "$FK_EPOCH"
}
# the package a real build gives, made once, for the stand-in to hand over
mkdir -p "$WORK/real"
chmod 777 "$WORK/real"
cp "$HERE/keyring/glyndor-pacman-key.asc" "$WORK/real/key.asc"; chmod 644 "$WORK/real/key.asc"
bash "$HERE/scripts/assemble/run-in-arch.sh" scripts/keyring/build-keyring.sh "$WORK/real" --key /work/key.asc --epoch "$FK_EPOCH" --out /work/out > /dev/null
GOODPKG="$WORK/real/out/$F"
check "a container that hands over the package it should: accepted" "0" "$(fake_run "cp $GOODPKG \"\$1/$F\"")"
check "the row is made on the host: size and hash of the file, not what a container says" \
	"glyndor	glyndor-keyring	1.0.$FK_EPOCH-1	any	$F	$(stat -c%s "$GOODPKG")	$(sha256sum "$GOODPKG" | cut -d' ' -f1)	no" "$(cat "$WORK/fman.tsv")"
check "a container that also writes a row of its own with another name, size and a path out of the folder: nothing of it is used" "0" \
	"$(fake_run "cp $GOODPKG \"\$1/$F\"; printf 'glyndor\tglyndor-keyring\t9.9.9-1\tany\t../../etc/evil\t1\t00\tno\n' > \"\$1/manifest-row.tsv\"; printf '{\"evil\": {\"replaces\": [\"linux\"]}}' > \"\$1/pkginfo.json\"" > /dev/null; grep -c -e evil -e '9.9.9' "$WORK/fman.tsv" "$WORK/finfo.json" | grep -c -v ':0$' || true)"
check "and the folder of the package holds only the one file" "$F" "$(cd "$WORK/fadm/glyndor" && echo *)"
check "the .PKGINFO data got the entry of the package and nothing else" "$F" "$(python3 -I -c 'import json,sys; print(*json.load(open(sys.argv[1])))' "$WORK/finfo.json")"
check "a container that leaves the package under another name" "1" "$(fake_run "cp $GOODPKG \"\$1/other.pkg.tar.zst\"")"
check "and adds nothing to the manifest" "0" "$(wc -c < "$WORK/fman.tsv")"
check "a container that leaves nothing" "1" "$(fake_run ':')"
check "a container that leaves a symbolic link with the right name" "1" "$(fake_run "ln -s /etc/passwd \"\$1/$F\"")"
check "and adds nothing to the data of .PKGINFO" "{}" "$(cat "$WORK/finfo.json")"
check "a container that leaves a link to the good package with the right name" "1" "$(fake_run "ln -s $GOODPKG \"\$1/$F\"")"
check "a container that leaves a directory with the right name" "1" "$(fake_run "mkdir \"\$1/$F\"")"
check "a container that leaves a package with an extra member" "1" "$(fake_run "python3 -I - $GOODPKG \"\$1/$F\" <<'PY'
import io, subprocess, sys, tarfile
data = subprocess.run(['zstd', '-dc', '-q', sys.argv[1]], stdout=subprocess.PIPE, check=True).stdout
buf = io.BytesIO()
with tarfile.open(fileobj=io.BytesIO(data)) as old, tarfile.open(fileobj=buf, mode='w') as new:
	for m in old:
		new.addfile(m, old.extractfile(m) if m.isreg() else None)
	extra = tarfile.TarInfo('etc/cron.d/evil'); extra.size = 2
	new.addfile(extra, io.BytesIO(b'x\\n'))
subprocess.run(['zstd', '-q', '-f', '-o', sys.argv[2]], input=buf.getvalue(), check=True)
PY")"
check "and the manifest and the data stay empty" "0" "$(wc -c < "$WORK/fman.tsv")"
prefilled() { # a run whose .PKGINFO data already holds an entry for the package
	rm -rf "$WORK/fadm"; mkdir -p "$WORK/fadm"
	: > "$WORK/fman.tsv"
	printf '{"%s": {}}' "$F" > "$WORK/finfo.json"
	# shellcheck disable=SC2016 # $1 is the folder the stand-in is given
	printf 'cp %s "$1/%s"\n' "$GOODPKG" "$F" > "$WORK/fake-build.sh"
	FAKE_BUILD="$WORK/fake-build.sh" rc_of bash "$FK/scripts/keyring/make-keyring.sh" --admitted "$WORK/fadm" --manifest "$WORK/fman.tsv" --pkginfo "$WORK/finfo.json" --epoch "$FK_EPOCH"
}
check "an entry for the package already in the .PKGINFO data" "1" "$(prefilled)"
check "and the manifest is as it was" "0" "$(wc -c < "$WORK/fman.tsv")"

finish
