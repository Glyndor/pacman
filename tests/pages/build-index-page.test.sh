#!/usr/bin/env bash
#
# build-index-page.sh: the landing page is written from the database that was built, so it lists what is served and
# nothing else, sends the reader to the README for the fingerprint (a page served from the repository cannot vouch
# for its own key), and prints no name or version that is not safe to put in HTML.
#
# Requires: python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/pages/build-index-page.sh"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
mkdir -p "$WORK/pk"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk/lib-0.1.0-1-any.pkg.tar.zst" lib 0.1.0-1 any
make_db "$WORK/db.tar.zst" "$WORK/pk"/*.pkg.tar.zst

check "the page is written" "0" "$(rc_of bash "$SCRIPT" "$WORK/db.tar.zst" "$WORK/index.html")"
check "it lists each package with its version and its install command" "2" "$(grep -c '^<li>' "$WORK/index.html")"
check "acme is there with its version" "1" "$(grep -c '<code>acme</code> 1.2.3-1: <code>curl -fsSL https://pacman.glyndor.net/install/acme | sudo sh</code>' "$WORK/index.html")"
check "it says that the command upgrades the system" "1" "$(grep -c 'upgrades the system' "$WORK/index.html")"
check "it sends the reader to the README for the fingerprint" "1" "$(grep -c 'github.com/Glyndor/pacman#readme' "$WORK/index.html")"
check "it has no script, no external stylesheet and no image" "0" "$(grep -c -e '<script' -e 'stylesheet' -e '<img' "$WORK/index.html" || true)"
check "a page that already exists is not overwritten" "1" "$(rc_of bash "$SCRIPT" "$WORK/db.tar.zst" "$WORK/index.html")"
check "a database that is not one" "1" "$(printf 'x' > "$WORK/bad"; rc_of bash "$SCRIPT" "$WORK/bad" "$WORK/other.html")"
check "no arguments is a usage error" "2" "$(rc_of bash "$SCRIPT")"

finish
