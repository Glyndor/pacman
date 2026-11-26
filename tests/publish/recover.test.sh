#!/usr/bin/env bash
#
# recover.sh end to end: a publication killed in the middle of its database group, against a bucket that is a folder, a
# real HTTP server on that folder and a stand-in for the Cloudflare API. The recovery has to leave a repository that the
# next publication can read, with the edge told, and has to fail when it cannot.
#
# Requires: gpg, python3, zstd, curl, setsid.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/publish/recover.sh"
make_gpg_key "$WORK/key"
FPR="$(cat "$WORK/key/fpr")"
mkdir -p "$WORK/bin" "$WORK/bucket" "$WORK/state" "$WORK/pk1" "$WORK/pk2" "$WORK/first"
cp "$FIXTURES/fake-aws" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export AWS_ACCESS_KEY_ID=id AWS_SECRET_ACCESS_KEY=secret AWS_ENDPOINT_URL=https://example.invalid
export FAKE_BUCKET="$WORK/bucket" FAKE_LOG="$WORK/log"
python3 -I "$FIXTURES/server.py" "$WORK/bucket" "$WORK/port" --state "$WORK/state" &
SERVER=$!
trap 'kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
until [ -s "$WORK/port" ]; do sleep 0.1; done
CF_API="http://127.0.0.1:$(cat "$WORK/port")"
export CF_API CF_ZONE=0123456789abcdef0123456789abcdef CF_TOKEN=token0123456789
export VERIFY_ATTEMPTS=2 VERIFY_DELAY=0
URL="http://127.0.0.1:$(cat "$WORK/port")"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk1/acme-1.2.2-1-x86_64.pkg.tar.zst" acme 1.2.2-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk2/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
: > "$WORK/first/served.tsv"; : > "$WORK/first/no-state"
T0="2026-11-23T06:00:00Z"; T1="2026-11-24T06:00:00Z"
N=0
signed() { # <packages dir> <served dir> <now>: a signed tree in $T, and what read-served.sh would keep of it in $PREV
	N=$((N + 1)); T="$WORK/t$N"
	make_tree "$T" "$1"/*.pkg.tar.zst
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/key/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$T" --manifest "$T.manifest" --pkginfo "$T.pkginfo.json" \
		--served "$2" --public-key "$WORK/key/pub.asc" --fingerprint "$FPR" --now "$3" > /dev/null
	PREV="$WORK/prev$N"; mkdir -p "$PREV"; D="$T/arch/x86_64"
	cp "$D/glyndor.db.tar.zst" "$D/glyndor.db.tar.zst.sig" "$PREV/"; cp "$D/glyndor.state" "$PREV/state"; cp "$D/glyndor.state.sig" "$PREV/state.sig"
	python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$D/glyndor.db.tar.zst" | awk -F'\t' '{ print $1 "\t" $2 "\t" $5 "\t" $3 }' > "$PREV/served.tsv"
}
publish() { # <previous dir> <now>: the upload alone
	bash "$HERE/scripts/publish/sync-archive.sh" --tree "$T" --previous "$1" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --now "$2"
}
cut_after() { # <previous dir> <now> <name>: the upload of $T, killed once that object of arch/x86_64 is written
	# shellcheck disable=SC2016 # $$ is the shell of the new session, which becomes the publication
	{ FAKE_DIE_AFTER="arch/x86_64/$3" setsid --wait bash -c 'FAKE_DIE_GROUP=$$ exec bash "$@"' cut "$HERE/scripts/publish/sync-archive.sh" \
		--tree "$T" --previous "$1" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --now "$2" > "$WORK/cut.out" 2>&1 || true; } 2> /dev/null
}
echo none > "$WORK/floor-none"
recover() { # <previous dir> <now> [options]
	bash "$SCRIPT" --tree "$T" --previous "$1" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --url "$URL" \
		--floor "${FLOOR:-$WORK/floor-none}" --now "$2" "${@:3}"
}
served() { # <now>: whether the next publication can read what is served
	rm -rf "$WORK/read"
	bash "$HERE/scripts/metadata/read-served.sh" --url "$URL" --out "$WORK/read" --key "$WORK/key/pub.asc" --floor "$WORK/floor-none" --now "$1" > /dev/null 2>&1 && echo yes || echo no
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
posts() { local n; n="$(grep -c '^POST' "$WORK/state/requests.log" 2> /dev/null || true)"; echo "${n:-0}"; }
db() { sha256sum "$WORK/bucket/arch/x86_64/glyndor.db.tar.zst" | cut -d' ' -f1; }
at_v1() { # a bucket that serves V1, and V2 signed on it
	rm -rf "$WORK/bucket/arch" "$WORK/bucket/.meta" "$FAKE_LOG" "$WORK/state/requests.log"
	signed "$WORK/pk1" "$WORK/first" "$T0"; V1PREV="$PREV"; V1DB="$(sha256sum "$D/glyndor.db.tar.zst" | cut -d' ' -f1)"
	publish "$WORK/first" "$T0" > /dev/null
	signed "$WORK/pk2" "$V1PREV" "$T1"; : > "$FAKE_LOG"
}

at_v1
cut_after "$V1PREV" "$T1" glyndor.db
check "after a publication killed in the database group the next one cannot read what is served" "no" "$(served "$T1")"
: > "$FAKE_LOG"
check "the recovery succeeds" "0" "$(rc_of recover "$V1PREV" "$T1")"
check "and says that what is served holds together" "1" "$(says 'recovered: the repository served at')"
check "the previous database is served again" "$V1DB" "$(db)"
check "and the next publication can read it" "yes" "$(served "$T1")"
check "the edge was told" "1" "$([ "$(posts)" -ge 1 ] && echo 1 || echo 0)"

at_v1
cut_after "$V1PREV" "$T1" glyndor.state.sig
: > "$FAKE_LOG"
check "a publication killed after its last write: the recovery succeeds without writing" "0 0" "$(rc_of recover "$V1PREV" "$T1") $(grep -c . "$FAKE_LOG" || true)"
check "and still tells the edge" "1" "$([ "$(posts)" -ge 1 ] && echo 1 || echo 0)"

at_v1
cut_after "$V1PREV" "$T1" glyndor.db
printf 'x' >> "$WORK/bucket/arch/x86_64/glyndor.db"; : > "$FAKE_LOG"
check "a third content fails the recovery, with nothing written and the edge not told" "1 0 0" \
	"$(rc_of recover "$V1PREV" "$T1") $(grep -c . "$FAKE_LOG" || true) $(posts)"

at_v1
cut_after "$V1PREV" "$T1" glyndor.db
check "a repository that still cannot be read after the restore fails the recovery" "1" "$(rc_of recover "$V1PREV" 2026-11-01T00:00:00Z)"
check "after the attempts it is given" "1" "$(says 'still does not hold together')"

record() { printf '%s %s\n' "$1" "$2" > "$WORK/floor"; }
at_v1
cut_after "$V1PREV" "$T1" glyndor.db
record 1 "$V1DB"
check "a recovery after the previous state expired puts it back when it is the recorded one" "0 yes" \
	"$(FLOOR="$WORK/floor" rc_of recover "$V1PREV" 2027-03-01T00:00:00Z) $([ "$(db)" = "$V1DB" ] && echo yes || echo no)"
at_v1
cut_after "$V1PREV" "$T1" glyndor.db
: > "$FAKE_LOG"
check "an expired previous state that is neither recorded nor named is not put back: nothing written, the edge not told" "1 0 0" \
	"$(rc_of recover "$V1PREV" 2027-03-01T00:00:00Z) $(grep -c . "$FAKE_LOG" || true) $(posts)"
check "and says why" "1" "$(says 'neither the recorded one nor the one named')"
check "naming another is not enough" "1 0" \
	"$(rc_of recover "$V1PREV" 2027-03-01T00:00:00Z --expired-state "1 $(printf '%064d' 0)") $(grep -c . "$FAKE_LOG" || true)"
check "naming it puts it back" "0 yes" \
	"$(rc_of recover "$V1PREV" 2027-03-01T00:00:00Z --expired-state "1 $V1DB") $([ "$(db)" = "$V1DB" ] && echo yes || echo no)"
at_v1
cut_after "$V1PREV" "$T1" glyndor.state.sig
check "a dead run that had written the new group whole is recovered with an expired previous state, which is not read" "0" \
	"$(rc_of recover "$V1PREV" 2026-12-07T06:30:00Z --expired-state "1 $V1DB")"
check "an --expired-state that is no state" "2" "$(rc_of recover "$V1PREV" "$T1" --expired-state yes)"

at_v1
cut_after "$V1PREV" "$T1" glyndor.db
record 2 "$V1DB"; : > "$FAKE_LOG"
check "a previous repository older than the recorded one is not put back: nothing written, the edge not told" "1 0 0" \
	"$(FLOOR="$WORK/floor" rc_of recover "$V1PREV" "$T1") $(grep -c . "$FAKE_LOG" || true) $(posts)"
check "and says why" "1" "$(says 'is not one to put back')"

rm -rf "$WORK/bucket/arch" "$WORK/bucket/.meta" "$WORK/state/requests.log"
signed "$WORK/pk1" "$WORK/first" "$T0"
cut_after "$WORK/first" "$T0" glyndor.db
: > "$FAKE_LOG"
check "a first publication is not removed once a state is recorded" "1 0" \
	"$(FLOOR="$WORK/floor" rc_of recover "$WORK/first" "$T0") $(grep -c . "$FAKE_LOG" || true)"

rm -rf "$WORK/bucket/arch" "$WORK/bucket/.meta" "$WORK/state/requests.log"
signed "$WORK/pk1" "$WORK/first" "$T0"
cut_after "$WORK/first" "$T0" glyndor.db
check "a first publication killed in the middle is removed and the empty repository accepted" "0 0" \
	"$(rc_of recover "$WORK/first" "$T0") $(find "$WORK/bucket/arch/x86_64" -name 'glyndor.[ds]*' | wc -l)"

at_v1
: > "$FAKE_LOG"
rc=0; CF_TOKEN="" recover "$V1PREV" "$T1" > "$WORK/last.out" 2>&1 || rc=$?
check "a purge that cannot be made fails the recovery" "1 1" "$rc $(says 'CF_TOKEN is not configured')"

check "an option that is not known" "2" "$(rc_of bash "$SCRIPT" --nope x)"
check "an option with no value" "2" "$(rc_of bash "$SCRIPT" --tree)"
check "a missing option" "2" "$(rc_of bash "$SCRIPT" --tree "$T")"

finish
