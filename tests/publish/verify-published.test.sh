#!/usr/bin/env bash
#
# verify-published.sh against a real HTTP server on the loopback that serves what the test puts in its folder. The
# repository read back has to be, file by file, what was uploaded, and has to hold together the way a client reads
# it: signed by the key of the repository, with a state that is current and about that database, every package of the
# database served with the size it says. A copy that the edge still holds after a purge is read again, and a
# repository that never becomes the one uploaded is a failure.
#
# Requires: gpg, python3, zstd, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/publish/verify-published.sh"
NOW="2026-11-23T06:00:00Z"
make_gpg_key "$WORK/key"
make_gpg_key "$WORK/other"
mkdir -p "$WORK/pk" "$WORK/first" "$WORK/site" "$WORK/state"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/lib-0.1.0-1-any.pkg.tar.zst" lib 0.1.0-1 any
: > "$WORK/first/served.tsv"; : > "$WORK/first/no-state"
make_tree "$WORK/tree" "$WORK/pk"/*.pkg.tar.zst
GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/key/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$WORK/tree" --manifest "$WORK/tree.manifest" --pkginfo "$WORK/tree.pkginfo.json" \
	--served "$WORK/first" --public-key "$WORK/key/pub.asc" --fingerprint "$(cat "$WORK/key/fpr")" --now "$NOW" > /dev/null
printf 'KEY' > "$WORK/tree/glyndor-pacman-key.asc"; printf '<html>' > "$WORK/tree/index.html"; mkdir -p "$WORK/tree/install"; printf '#!/bin/sh\n' > "$WORK/tree/install/acme"
python3 -I "$FIXTURES/server.py" "$WORK/site" "$WORK/port" --state "$WORK/state" &
SERVER=$!
trap 'kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
until [ -s "$WORK/port" ]; do sleep 0.1; done
URL="http://127.0.0.1:$(cat "$WORK/port")"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
# says <words>: 1 when the output holds them (the run repeats a message once for each attempt)
says() { if grep -q -F -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }
serve() { rm -rf "$WORK/site"/* "$WORK/state"/*; mkdir -p "$WORK/state"; cp -r "$WORK/tree/." "$WORK/site/"; }
verify() { bash "$SCRIPT" --url "$URL" --tree "$WORK/tree" --public-key "${PUB:-$WORK/key/pub.asc}" --now "${AT:-$NOW}" --attempts "${ATTEMPTS:-2}" --delay 0 "$@"; }

serve
check "a repository that is the one uploaded" "0" "$(rc_of verify)"
check "says so" "1" "$(says 'is the one that was published')"
check "the same with the packages read in full" "0" "$(rc_of verify --deep)"

echo "-- read in full, a package must be served with a signature that verifies it"
serve; printf 'junk' > "$WORK/site/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "a package served with a signature that does not verify it is refused with --deep" "1" "$(rc_of verify --deep)"
check "and says that the signature does not verify the served package" "1" "$(says 'does not verify the served package')"
check "and without --deep the signature is only asked for, as before" "0" "$(rc_of verify)"
serve; rm "$WORK/site/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "a package whose signature is not served is refused with --deep" "1" "$(rc_of verify --deep)"

echo "-- what is served is not what was uploaded"
for f in glyndor.db glyndor.db.sig glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig; do
	serve; printf x >> "$WORK/site/arch/x86_64/$f"
	check "$f changed" "1" "$(rc_of verify)"
done
serve; rm "$WORK/site/arch/x86_64/glyndor.db"
check "a file of the group missing" "1" "$(rc_of verify)"
check "and the message names it" "1" "$(says 'glyndor.db answers 404')"
serve; printf 'other' > "$WORK/site/glyndor-pacman-key.asc"
check "the key changed" "1" "$(rc_of verify)"
serve; printf 'other' > "$WORK/site/install/acme"
check "an installer changed" "1" "$(rc_of verify)"
serve; rm "$WORK/site/index.html"
check "the page missing" "1" "$(rc_of verify)"

echo "-- it holds together the way a client reads it"
serve
check "a public key that is not the one that signed" "1" "$(PUB="$WORK/other/pub.asc" rc_of verify)"
check "a state that has expired" "1" "$(AT=2027-01-01T00:00:00Z rc_of verify)"
check "and says so" "1" "$(says 'expired')"
serve; rm "$WORK/site/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst"
check "a package of the database that is not served" "1" "$(rc_of verify)"
check "and the message names it" "1" "$(says 'lib-0.1.0-1-any.pkg.tar.zst answers')"
serve; rm "$WORK/site/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst.sig"
check "a package whose signature is not served" "1" "$(rc_of verify)"
serve; head -c 50 "$WORK/tree/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst" > "$WORK/site/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package served with another size than the database says" "1" "$(rc_of verify)"
serve; python3 -I - "$WORK/site/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read()); d[-1] ^= 1; open(sys.argv[1], "wb").write(d)
PY
check "a package with the same size and other bytes passes the quick read" "0" "$(rc_of verify)"
check "and does not pass the deep one" "1" "$(rc_of verify --deep)"

echo "-- a copy that the edge still holds"
serve; mkdir -p "$WORK/state/stale/arch/x86_64"
printf 'old' > "$WORK/state/stale/arch/x86_64/glyndor.db"; printf '1' > "$WORK/state/stale-count"
check "served stale once, read again, it is the one uploaded" "0" "$(ATTEMPTS=3 rc_of verify)"
printf '99' > "$WORK/state/stale-count"
check "served stale every time, it is not" "1" "$(ATTEMPTS=2 rc_of verify)"
check "and says that it was read twice" "1" "$(says 'attempt 2 of 2')"

echo "-- the options"
check "an address that is not https and not the loopback" "2" "$(rc_of bash "$SCRIPT" --url http://example.org --tree "$WORK/tree" --public-key "$WORK/key/pub.asc")"
check "attempts that are not a number" "2" "$(rc_of verify --attempts many)"
check "an option that is not known" "2" "$(rc_of verify --nope x)"
check "no tree" "2" "$(rc_of bash "$SCRIPT" --url "$URL")"
check "a tree without a file of the database group" "1" "$(rm "$WORK/tree/arch/x86_64/glyndor.state.sig"; rc_of verify)"

for u in 'http://127.0.0.1:1@evil.example.org/' 'http://127.0.0.1:1/@evil.example.org' 'http://127.0.0.1:abc' 'https://pacman.glyndor.net@evil.example.org' 'https://user:pass@pacman.glyndor.net' 'http://user@127.0.0.1:1' 'https://pacman.glyndor.net/path' 'ftp://pacman.glyndor.net' 'https://'; do
	check "an address that a glob would take, $u, is refused whole" "2" "$(rc_of bash "$SCRIPT" --url "$u" --tree "$WORK/tree" --public-key "$WORK/key/pub.asc")"
done
finish
