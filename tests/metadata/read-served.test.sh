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
read_it() { # [options]: the result is in $WORK/out
	rm -rf "$WORK/out"
	bash "$SCRIPT" --url "$URL" --out "$WORK/out" --key "${PUB:-$WORK/key/pub.asc}" --now "${AT:-$NOW}" "$@"
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
for f in glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig; do
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
check "and says so" "1" "$(says 'expired')"
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

echo "-- the address and the options"
check "an address that is not https and not the loopback" "2" "$(rc_of bash "$SCRIPT" --url http://example.org --out "$WORK/o1")"
check "an address with a different scheme" "2" "$(rc_of bash "$SCRIPT" --url ftp://example.org --out "$WORK/o2")"
check "an output folder that exists" "2" "$(mkdir -p "$WORK/o3"; rc_of bash "$SCRIPT" --url "$URL" --out "$WORK/o3")"
check "an option that is not known" "2" "$(rc_of read_it --nope x)"
check "no address" "2" "$(rc_of bash "$SCRIPT" --out "$WORK/o4")"
check "a server that is not there is not an empty repository" "1" "$(rc_of bash "$SCRIPT" --url http://127.0.0.1:9 --out "$WORK/o5" --first-publication --key "$WORK/key/pub.asc")"
check "a public key that is not a key" "2" "$(printf 'x' > "$WORK/badkey"; PUB="$WORK/badkey" rc_of read_it)"

finish
