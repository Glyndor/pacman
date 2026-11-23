#!/usr/bin/env bash
#
# sign-tree.sh: the one step that holds the signing key. It signs a tree only if the tree is what the
# admission said (the packages and nothing else, all regular files, each with the size and hash of the manifest;
# the database is written by the step itself, never received), only with the key whose fingerprint it was given, and it reads
# every signature back with the public key before it reports anything. The key is never in an argument
# and never in the output.
#
# Requires: gpg, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/sign/sign-tree.sh"
NOW="2026-11-23T06:00:00Z"
make_gpg_key "$WORK/key"
make_gpg_key "$WORK/other"
FPR="$(cat "$WORK/key/fpr")"
SECRET="$(cat "$WORK/key/secret.asc")"
mkdir -p "$WORK/pk"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/lib-0.1.0-1-any.pkg.tar.zst" lib 0.1.0-1 any
mkdir -p "$WORK/first"
: > "$WORK/first/served.tsv"
: > "$WORK/first/no-state"
N=0
fresh() { N=$((N + 1)); T="$WORK/t$N"; make_tree "$T" "$WORK/pk"/*.pkg.tar.zst; D="$T/arch/x86_64"; }
sign() { # [extra options]: sign $T with the key of the test
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="${KEY-$SECRET}" bash "$SCRIPT" --tree "$T" --manifest "$T.manifest" --pkginfo "$T.pkginfo.json" --served "${SERVED:-$WORK/first}" \
		--public-key "${PUB:-$WORK/key/pub.asc}" --fingerprint "${FINGERPRINT:-$FPR}" --now "$NOW" "$@"
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }

fresh
check "a tree that is what was admitted is signed" "0" "$(rc_of sign)"
check "the signatures are there for every package, both copies of the database and the state" \
	"acme-1.2.3-1-x86_64.pkg.tar.zst.sig glyndor.db.sig glyndor.db.tar.zst.sig glyndor.state.sig lib-0.1.0-1-any.pkg.tar.zst.sig" \
	"$(cd "$D" && echo *.sig)"
gpg --homedir "$WORK/v" --batch --quiet --import "$WORK/key/pub.asc" 2> /dev/null || { mkdir -m 700 "$WORK/v"; gpg --homedir "$WORK/v" --batch --quiet --import "$WORK/key/pub.asc" 2> /dev/null; }
gpg --homedir "$WORK/v" --batch --export > "$WORK/ring.gpg"
allgood=0
for f in "$D"/*.pkg.tar.zst "$D"/glyndor.db "$D"/glyndor.db.tar.zst "$D"/glyndor.state; do
	gpgv --keyring "$WORK/ring.gpg" "$f.sig" "$f" > /dev/null 2>&1 || allgood=$((allgood + 1))
done
check "each one verifies with the public key, checked here with gpgv on my own" "0" "$allgood"
check "a signature of one package does not verify another" "1" "$(gpgv --keyring "$WORK/ring.gpg" "$D/lib-0.1.0-1-any.pkg.tar.zst.sig" "$D/acme-1.2.3-1-x86_64.pkg.tar.zst" > /dev/null 2>&1 && echo 0 || echo 1)"
check "the signatures are binary, as pacman reads them" "0" "$(head -c 1 "$D/glyndor.db.sig" | grep -c -- '-' || true)"
check "the state is the first one" "1" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$D/glyndor.state" sequence)"
check "the state is valid for the databases that were signed" "0" "$(rc_of python3 -I "$HERE/scripts/metadata/dbtool.py" state-check "$D/glyndor.state" --db "$D/glyndor.db.tar.zst" --now "$NOW")"
check "the key does not appear in the output" "0" "$(grep -c -e 'BEGIN PGP' -e "$(printf '%s' "$SECRET" | sed -n '3p')" "$WORK/last.out" || true)"
check "no process of gpg that holds the key is left running" "0" "$(pgrep -f "gnupg" -a 2> /dev/null | grep -c "$WORK" || true)"

echo "-- a second run over the state that was served"
mkdir -p "$WORK/second"
cp "$D/glyndor.state" "$WORK/second/state"
printf 'acme\t1.2.3-1\t0\tacme-1.2.3-1-x86_64.pkg.tar.zst\nlib\t0.1.0-1\t0\tlib-0.1.0-1-any.pkg.tar.zst\n' > "$WORK/second/served.tsv"
fresh
check "is signed" "0" "$(SERVED="$WORK/second" rc_of sign)"
check "and its sequence is 2" "2" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$D/glyndor.state" sequence)"
mkdir -p "$WORK/lost"; : > "$WORK/lost/served.tsv"
fresh
check "a served folder with neither a state nor the mark of a first publication is refused" "1" "$(SERVED="$WORK/lost" rc_of sign)"
check "and nothing was signed" "0" "$(find "$D" -name '*.sig' | wc -l)"

echo "-- a tree that is not what was admitted is not signed, and the key is not read"
unsigned() { find "$D" -name '*.sig' | wc -l; }
fresh; touch "$D/extra.txt"
check "a file that is not a package or a database" "1" "$(rc_of sign)"
check "and nothing was signed" "0" "$(unsigned)"
fresh; rm "$D/lib-0.1.0-1-any.pkg.tar.zst"
check "a missing package" "1" "$(rc_of sign)"
fresh; printf x >> "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package whose bytes are not the admitted ones" "1" "$(rc_of sign)"
fresh; rm "$D/lib-0.1.0-1-any.pkg.tar.zst"; ln -s "$WORK/pk/lib-0.1.0-1-any.pkg.tar.zst" "$D/lib-0.1.0-1-any.pkg.tar.zst"
check "a package that is a symbolic link" "1" "$(rc_of sign)"
fresh; ln "$D/acme-1.2.3-1-x86_64.pkg.tar.zst" "$D/acme.hard"
check "a file with a second hard link" "1" "$(rc_of sign)"
fresh; python3 -I "$FIXTURES/mkpkg.py" "$WORK/zed-1.0.0-1-any.pkg.tar.zst" zed 1.0.0-1 any; cp "$WORK/zed-1.0.0-1-any.pkg.tar.zst" "$D/"
check "a package that was not admitted" "1" "$(rc_of sign)"
fresh; cp "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" "$D/glyndor.db.tar.zst"
check "a database that arrives with the tree (it is written here, not received)" "1" "$(rc_of sign)"
check "and nothing of it was signed" "0" "$(unsigned)"
fresh; cp "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" "$D/glyndor.files.tar.zst"
check "a files database in the tree, which nobody asked for" "1" "$(rc_of sign)"
fresh; chmod g+w "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package that the group can write is not signed" "1" "$(rc_of sign)"
check "and the message says who could write it" "1" "$(says 'the group or others can write')"
check "and nothing was signed" "0" "$(unsigned)"
fresh; chmod o+w "$D"
check "a folder that others can write is not signed" "1" "$(rc_of sign)"
fresh; chmod 777 "$D/lib-0.1.0-1-any.pkg.tar.zst"
check "a file open to everybody is not signed" "1" "$(rc_of sign)"
fresh; mkdir "$D/sub"
check "a folder inside the tree" "1" "$(rc_of sign)"

echo "-- the database is written from what the admission read"
fresh; rc_of sign > /dev/null
check "the database that was signed is the one mkdb.py writes for the admitted data" "0" "$(rm -f "$WORK/ref.tar.zst"; python3 -I "$HERE/scripts/metadata/mkdb.py" --manifest "$T.manifest" --pkginfo "$T.pkginfo.json" --packages "$D" --out "$WORK/ref.tar.zst" > /dev/null 2>&1; cmp "$WORK/ref.tar.zst" "$D/glyndor.db.tar.zst" > /dev/null 2>&1; echo $?)"
check "and glyndor.db is a copy of it" "0" "$(cmp "$D/glyndor.db" "$D/glyndor.db.tar.zst" > /dev/null 2>&1; echo $?)"
fresh; python3 -I - "$T.pkginfo.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
info["acme-1.2.3-1-x86_64.pkg.tar.zst"]["replaces"] = ["linux\nprovides"]
json.dump(info, open(sys.argv[1], "w"))
PY
check "a .PKGINFO value that would write a line of its own into the desc" "1" "$(rc_of sign)"
check "and nothing was signed" "0" "$(unsigned)"
fresh; python3 -I - "$T.pkginfo.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
info["acme-1.2.3-1-x86_64.pkg.tar.zst"]["pgpsig"] = ["AAAA"]
json.dump(info, open(sys.argv[1], "w"))
PY
check "a .PKGINFO key that the database does not carry" "1" "$(rc_of sign)"
fresh; printf '{}' > "$T.pkginfo.json"
check "no .PKGINFO data for the admitted packages" "1" "$(rc_of sign)"
fresh; rm "$T.pkginfo.json"
check "a .PKGINFO data file that is not there" "1" "$(rc_of sign)"

echo "-- the key"
fresh
check "no key in the environment" "1" "$(KEY="" rc_of sign)"
check "and the message says nothing is signed without it" "1" "$(says 'nothing is signed without it')"
fresh
check "a key that is not a key" "1" "$(KEY="not a key" rc_of sign)"
fresh
check "another key than the fingerprint names" "1" "$(KEY="$(cat "$WORK/other/secret.asc")" rc_of sign)"
check "and the message says so" "1" "$(says "not the one named")"
fresh
check "two secret keys in the environment" "1" "$(KEY="$SECRET
$(cat "$WORK/other/secret.asc")" rc_of sign)"
fresh
check "a public key of another key than the fingerprint" "1" "$(PUB="$WORK/other/pub.asc" rc_of sign)"
fresh
check "a fingerprint in lower case is refused" "2" "$(FINGERPRINT="$(printf '%s' "$FPR" | tr 'A-F' 'a-f')" rc_of sign)"
fresh
check "a fingerprint that is not 40 digits is refused" "2" "$(FINGERPRINT="ABCD" rc_of sign)"
fresh
check "an option that is not known" "2" "$(rc_of sign --nope x)"
check "an option with no value" "2" "$(rc_of bash "$SCRIPT" --tree)"
check "no option at all" "2" "$(rc_of bash "$SCRIPT")"
check "nothing was signed by the last refusal" "0" "$(unsigned)"

finish
