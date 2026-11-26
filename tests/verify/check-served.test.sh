#!/usr/bin/env bash
#
# check-served.sh against a real HTTP server on the loopback: the published repository read the way a client reads it,
# with no tree to compare it with. The database and the state against the key of the repository, every package with a
# signature and the size the database says, and the key at the root the one of the repository.
#
# Requires: gpg, python3, zstd, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/verify/check-served.sh"
NOW="2026-11-23T06:00:00Z"
make_gpg_key "$WORK/key"
mkdir -p "$WORK/pk" "$WORK/first" "$WORK/site"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
: > "$WORK/first/served.tsv"; : > "$WORK/first/no-state"
make_tree "$WORK/tree" "$WORK/pk"/*.pkg.tar.zst
GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/key/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$WORK/tree" --manifest "$WORK/tree.manifest" \
	--pkginfo "$WORK/tree.pkginfo.json" --served "$WORK/first" --public-key "$WORK/key/pub.asc" --fingerprint "$(cat "$WORK/key/fpr")" --now "$NOW" > /dev/null
cp "$WORK/key/pub.asc" "$WORK/tree/glyndor-pacman-key.asc"
python3 -I "$FIXTURES/server.py" "$WORK/site" "$WORK/port" &
SERVER=$!
trap 'kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
until [ -s "$WORK/port" ]; do sleep 0.1; done
URL="http://127.0.0.1:$(cat "$WORK/port")"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { if grep -q -F -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }
serve() { rm -rf "$WORK/site"/* "$WORK/out"; cp -r "$WORK/tree/." "$WORK/site/"; }
D="$WORK/site/arch/x86_64"
echo none > "$WORK/floor-none"
check_it() { bash "$SCRIPT" --url "$URL" --key "${KEY:-$WORK/key/pub.asc}" --floor "${FLOOR:-$WORK/floor-none}" --now "${AT:-$NOW}" --out "$WORK/out" "$@"; }

serve
check "a repository that holds together" "0" "$(rc_of check_it)"
check "says how many packages and that the state is current" "1" "$(says '1 package(s), the state is current')"
check "what it read is kept for the checks that follow" "acme" "$(cut -f1 "$WORK/out/served.tsv")"
serve; rm "$D/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "a package whose signature is not served" "1" "$(rc_of check_it)"
serve; rm "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package that is not served" "1" "$(rc_of check_it)"
serve; head -c 40 "$WORK/tree/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst" > "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package served with another size than the database says" "1" "$(rc_of check_it)"
check "and says that it is not the package the database describes" "1" "$(says 'is not the package the database describes')"
serve; cp "$WORK/tree/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst" "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"; printf 'X' | dd of="$D/acme-1.2.3-1-x86_64.pkg.tar.zst" bs=1 seek=40 conv=notrunc 2> /dev/null
check "a package served with the size of the database and other bytes is refused too (its sha256 is what counts)" "1" "$(rc_of check_it)"
serve; printf 'junk' > "$D/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "a package served with a signature that does not verify it is refused" "1" "$(rc_of check_it)"
check "and says so" "1" "$(says 'does not verify it')"
serve; printf x >> "$D/glyndor.db.tar.zst"
check "a database changed after it was signed" "1" "$(rc_of check_it)"
serve; printf 'another key' > "$WORK/site/glyndor-pacman-key.asc"
check "a key at the root that is not the key of this repository" "1" "$(rc_of check_it)"
check "and says so" "1" "$(says 'is not the key of this repository')"
serve; rm "$WORK/site/glyndor-pacman-key.asc"
check "no key at the root" "1" "$(rc_of check_it)"
serve
check "a state that has expired" "1" "$(AT=2027-02-01T00:00:00Z rc_of check_it)"
check "a public key that did not sign it" "1" "$(rm -rf "$WORK/out"; make_gpg_key "$WORK/other"; KEY="$WORK/other/pub.asc" rc_of check_it)"
check "a server with nothing on it is not a sound repository" "1" "$(rm -rf "$WORK/site"/* "$WORK/out"; rc_of check_it)"
check "an option that is not known" "2" "$(rc_of check_it --nope x)"
printf '2 %064d\n' 0 > "$WORK/floor-newer"
serve; rm -rf "$WORK/out"
check "a served state older than the recorded one fails the check of what clients see" "1" "$(FLOOR="$WORK/floor-newer" rc_of check_it)"
check "and says why" "1" "$(says 'an earlier signed repository was put back')"
check "no address" "2" "$(rc_of bash "$SCRIPT")"

finish
