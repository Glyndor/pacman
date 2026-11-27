#!/usr/bin/env bash
#
# publish.sh end to end against a bucket that is a folder, a real HTTP server on that folder and a stand-in for the
# Cloudflare API: upload, purge, read back. A red run has to leave the repository whole: when what is served is not what
# was uploaded, or the purge is refused, the previous database group is written again and the edge is told.
#
# Requires: gpg, python3, zstd, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
# The temporary keyrings the run makes are all under $WORK, the ones the scripts make included: every one of them is
# closed on the way out, and the folder of sockets GnuPG made for each one is removed with it: none is left running,
# and none is left behind.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"
close_agents() {
	local dir
	for dir in "$WORK"/*/home "$WORK"/signhome "$TMPDIR"/*/gnupg "$TMPDIR"/*/verify; do
		[ -d "$dir" ] || continue
		gpgconf --homedir "$dir" --kill all > /dev/null 2>&1 || true
		gpgconf --homedir "$dir" --remove-socketdir > /dev/null 2>&1 || true
	done
}
SCRIPT="$HERE/scripts/publish/publish.sh"
make_gpg_key "$WORK/key"
FPR="$(cat "$WORK/key/fpr")"
mkdir -p "$WORK/bin" "$WORK/bucket" "$WORK/state" "$WORK/pk1" "$WORK/pk2" "$WORK/first"
cp "$FIXTURES/fake-aws" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export AWS_ACCESS_KEY_ID=id AWS_SECRET_ACCESS_KEY=secret AWS_ENDPOINT_URL=https://example.invalid
export FAKE_BUCKET="$WORK/bucket" FAKE_LOG="$WORK/log"
python3 -I "$FIXTURES/server.py" "$WORK/bucket" "$WORK/port" --state "$WORK/state" &
SERVER=$!
trap 'close_agents; kill "$SERVER" 2> /dev/null || true; rm -rf "$WORK"' EXIT
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
signed() { # <packages dir> <served dir> <now>: $T is a signed tree, $P the key, page and installer built beside it, $PREV what read-served.sh would keep of it
	N=$((N + 1)); T="$WORK/t$N"
	make_tree "$T" "$1"/*.pkg.tar.zst
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/key/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$T" --manifest "$T.manifest" --pkginfo "$T.pkginfo.json" \
		--served "$2" --public-key "$WORK/key/pub.asc" --fingerprint "$FPR" --now "$3" > /dev/null
	P="$WORK/pages$N"; mkdir -p "$P/install"
	printf 'KEY' > "$P/glyndor-pacman-key.asc"; printf '<html>' > "$P/index.html"; printf '#!/bin/sh\n' > "$P/install/acme"
	PREV="$WORK/prev$N"; mkdir -p "$PREV"; D="$T/arch/x86_64"
	cp "$D/glyndor.db.tar.zst" "$D/glyndor.db.tar.zst.sig" "$PREV/"; cp "$D/glyndor.state" "$PREV/state"; cp "$D/glyndor.state.sig" "$PREV/state.sig"
	python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$D/glyndor.db.tar.zst" | awk -F'\t' '{ print $1 "\t" $2 "\t" $5 "\t" $3 }' > "$PREV/served.tsv"
}
publish() { # <previous dir> <now>
	bash "$SCRIPT" --tree "${TREE:-$T}" --pages "${PAGES:-$P}" --previous "$1" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --url "$URL" --now "$2"
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { if grep -q -F -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }
posts() { grep -c '^POST' "$WORK/state/requests.log" 2> /dev/null || true; }
db() { sha256sum "$WORK/bucket/arch/x86_64/glyndor.db.tar.zst" | cut -d' ' -f1; }

signed "$WORK/pk1" "$WORK/first" "$T0"; V1="$PREV"; V1DB="$(sha256sum "$D/glyndor.db.tar.zst" | cut -d' ' -f1)"
check "a first publication is uploaded, purged and read back" "0" "$(rc_of publish "$WORK/first" "$T0")"
check "and says that it was read back" "1" "$(says 'read back from')"
check "and prints the state it published, which is what an operator records" "1" "$(says "the state published: 1 $V1DB")"
check "the bucket holds the new database" "$V1DB" "$(db)"
check "the edge was told once" "1" "$(posts)"

echo "-- a read-back that fails puts the previous repository back"
signed "$WORK/pk2" "$V1" "$T1"; V2DB="$(sha256sum "$D/glyndor.db.tar.zst" | cut -d' ' -f1)"
rm -f "$WORK/state/"*.log; mkdir -p "$WORK/state/stale/arch/x86_64"; printf 'old' > "$WORK/state/stale/arch/x86_64/glyndor.db"; printf '99' > "$WORK/state/stale-count"
check "an edge that keeps serving another database fails the run" "1" "$(rc_of publish "$V1" "$T1")"
check "and says what it does" "1" "$(says 'putting the previous repository back')"
check "the bucket holds the previous database again" "$V1DB" "$(db)"
check "and the edge was told again" "2" "$(posts)"
check "the previous state is back too" "0" "$(cmp "$WORK/bucket/arch/x86_64/glyndor.state" "$V1/state" > /dev/null 2>&1; echo $?)"
rm -rf "$WORK/state/stale" "$WORK/state/stale-count"

echo "-- a purge that is refused"
rm -f "$WORK/state/"*.log; : > "$WORK/state/purge-fails"
check "fails the run" "1" "$(rc_of publish "$V1" "$T1")"
check "and the previous repository is put back" "$V1DB" "$(db)"
rm -f "$WORK/state/purge-fails"

echo "-- an upload that is cut"
rm -f "$WORK/state/"*.log; export FAKE_FAIL_KEY=glyndor.state.sig FAKE_FAIL_ONCE=1; rm -f "$WORK/bucket/.failed"
check "fails the run" "1" "$(rc_of publish "$V1" "$T1")"
check "and the previous repository is still the one served" "$V1DB" "$(db)"
check "and the edge was told, since the group was being written" "1" "$(posts)"
unset FAKE_FAIL_KEY FAKE_FAIL_ONCE

echo "-- what the job downloaded holds only what was signed"
rm -f "$WORK/state/"*.log; : > "$WORK/log"
cp -r "$T" "$WORK/tcopy1"; printf '<html>evil' > "$WORK/tcopy1/index.html"
check "a page that came with the signed tree is refused" "1" "$(TREE="$WORK/tcopy1" rc_of publish "$V1" "$T1")"
check "and nothing was written" "0" "$(wc -l < "$WORK/log")"
cp -r "$T" "$WORK/tcopy2"; mkdir "$WORK/tcopy2/install"; printf 'x' > "$WORK/tcopy2/install/acme"
check "an installer that came with it is refused" "1" "$(TREE="$WORK/tcopy2" rc_of publish "$V1" "$T1")"
cp -r "$T" "$WORK/tcopy3"; printf 'KEY' > "$WORK/tcopy3/glyndor-pacman-key.asc"
check "a key that came with it is refused" "1" "$(TREE="$WORK/tcopy3" rc_of publish "$V1" "$T1")"
cp -r "$T" "$WORK/tcopy4"; ln -s /etc/passwd "$WORK/tcopy4/arch/x86_64/link"
check "a link in the tree is refused" "1" "$(TREE="$WORK/tcopy4" rc_of publish "$V1" "$T1")"
cp -r "$T" "$WORK/tcopy5"; mkdir "$WORK/tcopy5/arch/x86_64/sub"
check "a folder inside arch/x86_64 is refused" "1" "$(TREE="$WORK/tcopy5" rc_of publish "$V1" "$T1")"
cp -r "$T" "$WORK/tcopy6"; cp "$WORK/pk1/acme-1.2.2-1-x86_64.pkg.tar.zst" "$WORK/tcopy6/arch/x86_64/"
mkdir -m 700 "$WORK/signhome"; gpg --homedir "$WORK/signhome" --batch --quiet --import "$WORK/key/secret.asc" 2> /dev/null
gpg --homedir "$WORK/signhome" --batch --yes --quiet --pinentry-mode loopback --passphrase '' --detach-sign --output "$WORK/tcopy6/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst.sig" "$WORK/tcopy6/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst"
gpgconf --homedir "$WORK/signhome" --kill all > /dev/null 2>&1 || true
gpgconf --homedir "$WORK/signhome" --remove-socketdir > /dev/null 2>&1 || true
check "a package that the signed database does not list is refused" "1" "$(TREE="$WORK/tcopy6" rc_of publish "$V1" "$T1")"
check "and says that the packages are not the ones the database lists" "1" "$(says 'not the ones the signed database lists')"
cp -r "$T" "$WORK/tcopy7"; printf 'other bytes' > "$WORK/tcopy7/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package whose bytes are not the ones the database gives is refused (the signature fails first)" "1" "$(TREE="$WORK/tcopy7" rc_of publish "$V1" "$T1")"
check "and nothing was written by any of them" "0" "$(wc -l < "$WORK/log")"
mkdir -p "$WORK/pages-bad"; printf 'x' > "$WORK/pages-bad/other.txt"
check "a pages folder with a file that is not the key, the page or an installer is refused" "1" "$(PAGES="$WORK/pages-bad" rc_of publish "$V1" "$T1")"

echo "-- the bucket holds another state than the one the run was built on"
rm -f "$WORK/state/"*.log; : > "$WORK/log"
cp "$V1/state" "$WORK/other-state"; printf 'tampered' >> "$WORK/other-state"
cp "$WORK/bucket/arch/x86_64/glyndor.state" "$WORK/state.bak"
cp "$WORK/other-state" "$WORK/bucket/arch/x86_64/glyndor.state"
check "a publication refuses to write" "1" "$(rc_of publish "$V1" "$T1")"
check "and says that it is not the state this run was built on" "1" "$(says 'is not the one this run was built on')"
check "and the other state is not overwritten by the restore either" "0" "$(cmp "$WORK/bucket/arch/x86_64/glyndor.state" "$WORK/other-state" > /dev/null 2>&1; echo $?)"
check "and nothing was written" "0" "$(wc -l < "$WORK/log")"
cp "$WORK/state.bak" "$WORK/bucket/arch/x86_64/glyndor.state"

echo "-- and when nothing goes wrong, the second publication is the new one"
rm -f "$WORK/state/"*.log
check "the update succeeds" "0" "$(rc_of publish "$V1" "$T1")"
check "the bucket holds the new database" "$V2DB" "$(db)"
check "the new package is served" "yes" "$([ -f "$WORK/bucket/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst" ] && echo yes || echo no)"
check "the option that is not known" "2" "$(rc_of bash "$SCRIPT" --nope x)"
check "no option at all" "2" "$(rc_of bash "$SCRIPT")"

finish
