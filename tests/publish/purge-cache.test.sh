#!/usr/bin/env bash
#
# purge-cache.sh against a stand-in for the Cloudflare API on the loopback: what is purged is a list of URLs derived
# from the tree (the database group, the key, the page, the installers, what was removed), never a package, never
# everything; it goes in batches of at most 30; the token goes in a header file and never in the command line; and any
# answer that is not a success is a failure.
#
# Requires: python3, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/publish/purge-cache.sh"
mkdir -p "$WORK/state" "$WORK/root"
python3 -I "$FIXTURES/server.py" "$WORK/root" "$WORK/port" --state "$WORK/state" &
SERVER=$!
trap 'kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
until [ -s "$WORK/port" ]; do sleep 0.1; done
CF_API="http://127.0.0.1:$(cat "$WORK/port")"
export CF_API
export CF_ZONE="0123456789abcdef0123456789abcdef"
export CF_TOKEN="token-for-the-test-0123456789"
T="$WORK/tree"
mkdir -p "$T/arch/x86_64" "$T/install"
for f in glyndor.db glyndor.db.sig glyndor.db.tar.zst glyndor.db.tar.zst.sig \
	 glyndor.state glyndor.state.sig acme-1-1-x86_64.pkg.tar.zst; do : > "$T/arch/x86_64/$f"; done
: > "$T/glyndor-pacman-key.asc"; : > "$T/index.html"; : > "$T/install/acme"; : > "$T/install/lib"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
reset() { rm -f "$WORK/state/"*.log "$WORK/state/purge-fails"; }
purge() { bash "$SCRIPT" --url https://pacman.example.org --tree "$T" "$@"; }
urls() { python3 -I -c 'import json,sys
for line in open(sys.argv[1]): print(*json.loads(line)["files"], sep="\n")' "$WORK/state/purged.log" | sort; }

reset
check "the purge succeeds" "0" "$(rc_of purge)"
check "it says how many URLs in how many requests" "1" "$(says 'purged 11 URL(s) in 1 request(s)')"
check "the list is the fixed names and nothing else" "https://pacman.example.org/
https://pacman.example.org/arch/x86_64/glyndor.db
https://pacman.example.org/arch/x86_64/glyndor.db.sig
https://pacman.example.org/arch/x86_64/glyndor.db.tar.zst
https://pacman.example.org/arch/x86_64/glyndor.db.tar.zst.sig
https://pacman.example.org/arch/x86_64/glyndor.state
https://pacman.example.org/arch/x86_64/glyndor.state.sig
https://pacman.example.org/glyndor-pacman-key.asc
https://pacman.example.org/index.html
https://pacman.example.org/install/acme
https://pacman.example.org/install/lib" "$(urls | head -11)"
check "no package is purged: it is named for its version and cached for a year" "0" "$(urls | grep -c 'pkg.tar.zst' || true)"
check "the token reached the API as a bearer header" "Bearer $CF_TOKEN" "$(cat "$WORK/state/auth.log")"
check "and is not in the output" "0" "$(grep -c "$CF_TOKEN" "$WORK/last.out" || true)"
check "the request went to the zone of the purge" "1" "$(grep -c "POST /zones/$CF_ZONE/purge_cache" "$WORK/state/requests.log")"

echo "-- more than 30 URLs go in batches"
for i in $(seq 1 40); do printf 'installer-%s' "$i" > "$T/install/p$i"; done
reset
check "the purge succeeds" "0" "$(rc_of purge)"
check "in two requests" "2" "$(grep -c '^POST' "$WORK/state/requests.log")"
check "none with more than 30 URLs" "0" "$(python3 -I -c 'import json,sys
print(sum(1 for line in open(sys.argv[1]) if len(json.loads(line)["files"]) > 30))' "$WORK/state/purged.log")"
rm -f "$T"/install/p*

echo "-- what was removed"
printf 'install/gone\nold/path.txt\n' > "$WORK/extra"
reset
check "the paths a publication removed are purged too" "0" "$(rc_of purge --extra "$WORK/extra")"
check "and they are in the list" "2" "$(urls | grep -c -e '/install/gone' -e '/old/path.txt' || true)"
printf 'install/x y\n' > "$WORK/extra-bad"
check "a path with a space is refused" "1" "$(rc_of purge --extra "$WORK/extra-bad")"
printf '../x\n' > "$WORK/extra-bad"
check "a path that climbs is refused" "1" "$(rc_of purge --extra "$WORK/extra-bad")"

echo "-- a refusal, and what is not allowed"
reset; : > "$WORK/state/purge-fails"
check "an answer that is not a success is a failure" "1" "$(rc_of purge)"
check "and the message says which URLs" "1" "$(says 'was refused (HTTP 400)')"
reset
check "no token" "1" "$(CF_TOKEN="" rc_of purge)"
check "no zone" "1" "$(CF_ZONE="" rc_of purge)"
check "a zone that is not a zone id" "1" "$(CF_ZONE="zone" rc_of purge)"
check "an API that is not Cloudflare's, which would receive the token" "2" "$(CF_API=https://evil.example.org rc_of purge)"
check "a tree without a file of the database group" "1" "$(rm "$T/arch/x86_64/glyndor.state"; rc_of purge)"
: > "$T/arch/x86_64/glyndor.state"
check "an origin that is not https" "2" "$(rc_of bash "$SCRIPT" --url http://pacman.example.org --tree "$T")"
for api in 'http://127.0.0.1:1@evil.example.org/' 'http://127.0.0.1:1/@evil.example.org' 'http://127.0.0.1:abc' 'http://127.0.0.1:' 'http://127.0.0.1:1.evil.example.org' 'http://user@127.0.0.1:1' 'https://api.cloudflare.com/client/v4@evil.example.org' 'https://api.cloudflare.com/client/v4/' 'http://127.0.0.1:1/x'; do
	check "an API address that a glob would take, $api, is refused whole" "2" "$(CF_API="$api" rc_of purge)"
done
check "an origin with a path" "2" "$(rc_of bash "$SCRIPT" --url https://pacman.example.org/x --tree "$T")"
check "an option that is not known" "2" "$(rc_of purge --nope x)"
check "a budget that is not a number" "2" "$(rc_of purge --budget soon)"
check "no tree" "2" "$(rc_of bash "$SCRIPT" --url https://pacman.example.org)"
check "an API that is not there is a failure" "1" "$(CF_API=http://127.0.0.1:9 rc_of purge --budget 10)"

finish
