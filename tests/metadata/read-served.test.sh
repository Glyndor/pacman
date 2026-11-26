#!/usr/bin/env bash
#
# read-served.sh: what the repository serves today, read the way a hostile network would hand it over. An
# empty bucket is a first publication only when the run says so and every object answers 404; a database
# without its state, a signature that does not verify, a state that has expired or belongs to another
# database, a server that answers an error, all stop the run, because a publication that treats any of them
# as "nothing there" would overwrite a good repository. The server is a real HTTP server on the loopback,
# and the repository it serves is signed by sign-tree.sh with a key made for the run.
#
# Requires: gpg, python3, zstd, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/metadata/read-served.sh"
NOW="2026-11-23T06:00:00Z"
make_gpg_key "$WORK/key"
make_gpg_key "$WORK/other"
mkdir -p "$WORK/pk" "$WORK/first"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/lib-0.1.0-1-any.pkg.tar.zst" lib 0.1.0-1 any
: > "$WORK/first/served.tsv"; : > "$WORK/first/no-state"

# publish <site> [key dir]: a signed repository in <site>
publish() {
	make_tree "$WORK/tree" "$WORK/pk"/*.pkg.tar.zst
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "${2:-$WORK/key}/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$WORK/tree" \
		--manifest "$WORK/tree.manifest" --pkginfo "$WORK/tree.pkginfo.json" --served "$WORK/first" --public-key "${2:-$WORK/key}/pub.asc" --fingerprint "$(cat "${2:-$WORK/key}/fpr")" \
		--now "$NOW" > /dev/null
	rm -rf "$1"; mkdir -p "$1"; cp -r "$WORK/tree/arch" "$1/"; rm -rf "$WORK/tree" "$WORK/tree.manifest" "$WORK/tree.pkginfo.json"
}
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkdir -p "$WORK/site"
( cd "$WORK/site" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 > "$WORK/server.log" 2>&1 ) &
SERVER=$!
trap 'kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
until curl --silent --max-time 2 "http://127.0.0.1:$PORT/" > /dev/null 2>&1; do sleep 0.2; done
URL="http://127.0.0.1:$PORT"
echo none > "$WORK/floor-none"
read_it() { # [options]: the result is in $WORK/out
	rm -rf "$WORK/out"
	bash "$SCRIPT" --url "$URL" --out "$WORK/out" --key "${PUB:-$WORK/key/pub.asc}" --floor "${FLOOR:-$WORK/floor-none}" --now "${AT:-$NOW}" "$@"
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }

rm -rf "$WORK/site/arch"
check "an empty repository without --first-publication is refused" "1" "$(rc_of read_it)"
check "and says that it will not publish from nothing" "1" "$(says 'not the first publication')"
check "an empty repository with --first-publication reads as nothing" "0" "$(rc_of read_it --first-publication)"
check "the served list is empty and there is no state" "0 yes" "$(wc -l < "$WORK/out/served.tsv" | tr -d ' ') $([ -e "$WORK/out/no-state" ] && echo yes || echo no)"

publish "$WORK/site"
check "a signed repository with a current state is read" "0" "$(rc_of read_it)"
check "what is served is name, pkgver, sha256 and file" "acme	1.2.3-1	$(sha256sum "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" | cut -d' ' -f1)	acme-1.2.3-1-x86_64.pkg.tar.zst" "$(head -1 "$WORK/out/served.tsv")"
check "its state is kept" "1" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$WORK/out/state" sequence)"
check "--first-publication against a repository that exists is read as it is" "0" "$(rc_of read_it --first-publication)"
check "and the mark of a first publication is not written" "no" "$([ -e "$WORK/out/no-state" ] && echo yes || echo no)"
check "and it still reads what is served" "2" "$(wc -l < "$WORK/out/served.tsv" | tr -d ' ')"

echo "-- what a hostile or broken server serves"
D="$WORK/site/arch/x86_64"
cp -r "$WORK/site" "$WORK/site-good"
for f in glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.db glyndor.db.sig glyndor.state glyndor.state.sig; do
	rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
printf 'another database' > "$D/glyndor.db"
check "a glyndor.db that is not the .tar.zst whose signature verifies is refused (pacman reads glyndor.db)" "1" "$(rc_of read_it)"
check "and says so" "1" "$(says 'glyndor.db is not the file glyndor.db.tar.zst')"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
printf 'another signature' > "$D/glyndor.db.sig"
check "a glyndor.db.sig that is not the signature that verifies is refused" "1" "$(rc_of read_it)"
check "and says so" "1" "$(says 'glyndor.db.sig is not the signature')"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
	rm "$D/$f"
	check "$f missing while the rest is served" "1" "$(rc_of read_it)"
	check "and says what is missing" "1" "$(says "$f answered 404")"
done
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
printf x >> "$D/glyndor.db.tar.zst"
check "a database changed after it was signed" "1" "$(rc_of read_it)"
check "and says that the signature does not verify" "1" "$(says 'does not verify')"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"; printf x >> "$D/glyndor.state"
check "a state changed after it was signed" "1" "$(rc_of read_it)"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
check "a repository signed by another key" "1" "$(PUB="$WORK/other/pub.asc" rc_of read_it)"
publish "$WORK/site" "$WORK/other"
check "a repository whose own key is another one is refused with the key of this repository" "1" "$(rc_of read_it)"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
check "a state that has expired" "1" "$(AT=2026-12-08T00:00:00Z rc_of read_it)"
check "and says so" "1" "$(says 'the state expired at')"
check "a state from the future" "1" "$(AT=2026-11-22T00:00:00Z rc_of read_it)"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"
cp "$D/glyndor.state" "$WORK/state-keep"; cp "$D/glyndor.state.sig" "$WORK/state-sig-keep"
publish "$WORK/site-other"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/zed-1.0.0-1-any.pkg.tar.zst" zed 1.0.0-1 any
publish "$WORK/site-new"
cp "$WORK/site-new/arch/x86_64/glyndor.state" "$D/glyndor.state"; cp "$WORK/site-new/arch/x86_64/glyndor.state.sig" "$D/glyndor.state.sig"
check "a good state of another database laid over this one" "1" "$(rc_of read_it)"
check "and says that it is about another database" "1" "$(says 'another database')"
rm -f "$WORK/pk/zed-1.0.0-1-any.pkg.tar.zst"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"

echo "-- the recorded state, which the bucket cannot change"
# Three publications one after another, each kept whole: what a bucket writer could serve again.
pub_n() { # <n> <served dir> <now> <extra package version>
	python3 -I "$FIXTURES/mkpkg.py" "$WORK/chain-pk/zed-$4-1-any.pkg.tar.zst" zed "$4-1" any
	make_tree "$WORK/c$1" "$WORK/chain-pk"/*.pkg.tar.zst
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/key/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$WORK/c$1" \
		--manifest "$WORK/c$1.manifest" --pkginfo "$WORK/c$1.pkginfo.json" --served "$2" --public-key "$WORK/key/pub.asc" \
		--fingerprint "$(cat "$WORK/key/fpr")" --now "$3" > /dev/null
	mkdir -p "$WORK/s$1"
	cp "$WORK/c$1/arch/x86_64/glyndor.db.tar.zst" "$WORK/c$1/arch/x86_64/glyndor.db.tar.zst.sig" "$WORK/s$1/"
	cp "$WORK/c$1/arch/x86_64/glyndor.state" "$WORK/s$1/state"; cp "$WORK/c$1/arch/x86_64/glyndor.state.sig" "$WORK/s$1/state.sig"
	python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$WORK/s$1/glyndor.db.tar.zst" | awk -F'\t' '{ print $1 "\t" $2 "\t" $5 "\t" $3 }' > "$WORK/s$1/served.tsv"
	rm -f "$WORK/chain-pk"/zed-*
}
serve() { rm -rf "$WORK/site"; mkdir -p "$WORK/site"; cp -r "$WORK/c$1/arch" "$WORK/site/"; }
record() { printf '# recorded\n%s %s\n' "$1" "$(sha256sum "$WORK/c$2/arch/x86_64/glyndor.db.tar.zst" | cut -d' ' -f1)" > "$WORK/floor"; }
mkdir -p "$WORK/chain-pk"; cp "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" "$WORK/chain-pk/"
pub_n 1 "$WORK/first" "$NOW" 1.0.0
pub_n 2 "$WORK/s1" "2026-11-24T06:00:00Z" 1.1.0
pub_n 3 "$WORK/s2" "2026-11-25T06:00:00Z" 1.2.0
id_of() { echo "$1 $(sha256sum "$WORK/c$1/arch/x86_64/glyndor.db.tar.zst" | cut -d' ' -f1)"; }
export FLOOR="$WORK/floor"; record 3 3
serve 1
check "an earlier state, signed and still current, served after newer publications is refused" "1" "$(AT=2026-11-26T00:00:00Z rc_of read_it)"
check "and says that an earlier repository was put back" "1" "$(says 'an earlier signed repository was put back')"
check "the same one, expired, is refused to be published over too" "1 1" \
	"$(AT=2027-03-01T00:00:00Z rc_of read_it --expired-state "$(id_of 3)") $(says 'an earlier signed repository was put back')"
serve 2
check "the one just before the recorded one is refused" "1" "$(AT=2026-11-26T00:00:00Z rc_of read_it)"
serve 3
check "the recorded one is read" "0" "$(AT=2026-11-26T00:00:00Z rc_of read_it)"
check "and expired it is refused when nobody asked to publish over it" "1 1" "$(AT=2027-03-01T00:00:00Z rc_of read_it) $(says 'the state expired at')"
check "and read to be published over when somebody did, with a warning" "0 1" \
	"$(AT=2027-03-01T00:00:00Z rc_of read_it --expired-state "$(id_of 3)") $(says '::warning::state 3 expired at')"
check "and what is served is what the next publication starts from" "3 2" \
	"$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$WORK/out/state" sequence) $(wc -l < "$WORK/out/served.tsv" | tr -d ' ')"
check "a state from the future is refused to be published over too" "1" "$(AT=2026-11-22T00:00:00Z rc_of read_it --expired-state "$(id_of 3)")"
# A state between the recorded one and the newest: not older than the record, and expired. Only naming it takes it.
record 1 1
serve 2
check "an expired state between the record and the newest is refused when the newest is the one asked for" "1 1" \
	"$(AT=2027-03-01T00:00:00Z rc_of read_it --expired-state "$(id_of 3)") $(says 'and the one asked for is')"
check "and when nothing is asked for" "1 1" "$(AT=2027-03-01T00:00:00Z rc_of read_it) $(says 'the state expired at')"
check "it says which state is served" "1" "$(says "the served state is '$(id_of 2)'")"
check "naming it takes it, whoever named it answering for it" "0" "$(AT=2027-03-01T00:00:00Z rc_of read_it --expired-state "$(id_of 2)")"
check "the right sequence with another database is refused" "1" \
	"$(AT=2027-03-01T00:00:00Z rc_of read_it --expired-state "2 $(printf '%064d' 0)")"
check "a state that has not expired still has to be the one named" "1" "$(AT=2026-11-26T00:00:00Z rc_of read_it --expired-state "$(id_of 3)")"
serve 3
record 2 2
check "a state newer than the recorded one is read, and the run says to record it" "0 1" \
	"$(AT=2026-11-26T00:00:00Z rc_of read_it) $(says 'record it so that it cannot be taken back')"
record 3 2
check "a state of the recorded sequence with another database is refused" "1 1" \
	"$(AT=2026-11-26T00:00:00Z rc_of read_it) $(says 'its database is not the recorded one')"
export FLOOR="$WORK/floor-none"
check "with nothing recorded an expired state is refused unless it is named" "1" "$(AT=2027-03-01T00:00:00Z rc_of read_it)"
check "and read when it is" "0" "$(AT=2027-03-01T00:00:00Z rc_of read_it --expired-state "$(id_of 3)")"
for bad in true "3" "3 abc" "$(id_of 3) x" "0 $(printf '%064d' 0)"; do
	check "--expired-state as '${bad:0:12}' is refused" "2" "$(rc_of read_it --expired-state "$bad")"
done
for bad in "" "three $(printf '%064d' 0)" "3 abc" "$(printf 'none\nnone')" "0 $(printf '%064d' 0)"; do
	printf '%s\n' "$bad" > "$WORK/floor-bad"
	check "a record that is '${bad:0:12}' is refused" "1 1" "$(FLOOR="$WORK/floor-bad" AT=2026-11-26T00:00:00Z rc_of read_it) $(says 'does not hold exactly one line')"
done
check "a record that is not there is refused" "1 1" "$(FLOOR="$WORK/nowhere" AT=2026-11-26T00:00:00Z rc_of read_it) $(says 'is not a readable regular file')"
rm -rf "$WORK/site/arch"; export FLOOR="$WORK/floor"; record 3 3
check "once a state is recorded, a repository that answers nothing is not a first publication" "1 1" \
	"$(rc_of read_it --first-publication) $(says 'does not say that nothing was published')"
unset FLOOR
# shellcheck disable=SC2016 # the line of the script is looked for as text
check "the record read when none is given is the one of the repository" "1" \
	"$(grep -c '^floor="$HERE/scripts/metadata/state-floor.txt"$' "$SCRIPT")"
rm -rf "$WORK/site"; cp -r "$WORK/site-good" "$WORK/site"

echo "-- the address and the options"
check "an address that is not https and not the loopback" "2" "$(rc_of bash "$SCRIPT" --url http://example.org --out "$WORK/o1")"
check "an address with a different scheme" "2" "$(rc_of bash "$SCRIPT" --url ftp://example.org --out "$WORK/o2")"
check "an output folder that exists" "2" "$(mkdir -p "$WORK/o3"; rc_of bash "$SCRIPT" --url "$URL" --out "$WORK/o3")"
check "an option that is not known" "2" "$(rc_of read_it --nope x)"
check "no address" "2" "$(rc_of bash "$SCRIPT" --out "$WORK/o4")"
check "a server that is not there is not an empty repository" "1" "$(rc_of bash "$SCRIPT" --url http://127.0.0.1:9 --out "$WORK/o5" --first-publication --key "$WORK/key/pub.asc")"
check "a public key that is not a key" "2" "$(printf 'x' > "$WORK/badkey"; PUB="$WORK/badkey" rc_of read_it)"

for u in 'http://127.0.0.1:1@evil.example.org/' 'http://127.0.0.1:1/@evil.example.org' 'http://127.0.0.1:abc' 'http://localhost:1@evil.example.org' 'https://pacman.glyndor.net@evil.example.org' 'https://user:pass@pacman.glyndor.net' 'ftp://pacman.glyndor.net' 'https://'; do
	check "an address that a glob would take, $u, is refused whole" "2" "$(rc_of bash "$SCRIPT" --url "$u" --out "$WORK/out-bad" --key "$WORK/key/pub.asc" --now "$NOW")"
done
finish
