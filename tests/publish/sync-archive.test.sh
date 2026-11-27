#!/usr/bin/env bash
#
# sync-archive.sh against a bucket that is a folder (tests/fixtures/pacman/fake-aws). What it has to guarantee is
# an order and a refusal, so the tests read the log of writes: packages and their signatures before anything
# that names them, the database group last and together, an existing package never overwritten (and a different
# hash under the same name a refusal before any write), a tree altered after the signer not uploaded at all, a
# group that is cut put back to the previous one (or removed on a first publication), and a replaced package
# deleted only when the signed state says its time has gone by.
#
# Requires: gpg, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/repo.sh"
SCRIPT="$HERE/scripts/publish/sync-archive.sh"
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
trap 'close_agents; rm -rf "$WORK"' EXIT
make_gpg_key "$WORK/key"
FPR="$(cat "$WORK/key/fpr")"
mkdir -p "$WORK/bin"
cp "$FIXTURES/fake-aws" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export AWS_ACCESS_KEY_ID=id AWS_SECRET_ACCESS_KEY=secret AWS_ENDPOINT_URL=https://example.invalid
export FAKE_BUCKET="$WORK/bucket" FAKE_LOG="$WORK/log"
mkdir -p "$WORK/pk1" "$WORK/pk2"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk1/acme-1.2.2-1-x86_64.pkg.tar.zst" acme 1.2.2-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk1/lib-0.1.0-1-any.pkg.tar.zst" lib 0.1.0-1 any
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk2/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
cp "$WORK/pk1/lib-0.1.0-1-any.pkg.tar.zst" "$WORK/pk2/"
mkdir -p "$WORK/first"
: > "$WORK/first/served.tsv"
: > "$WORK/first/no-state"
T0="2026-11-23T06:00:00Z"
T1="2026-11-24T06:00:00Z"
T2="2026-12-10T06:00:00Z"
N=0

# signed <packages dir> <served dir> <now>: a signed tree in $T, and its previous-state folder in $PREV
signed() {
	N=$((N + 1))
	T="$WORK/t$N"
	make_tree "$T" "$1"/*.pkg.tar.zst
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/key/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$T" --manifest "$T.manifest" --pkginfo "$T.pkginfo.json" \
		--served "$2" --public-key "$WORK/key/pub.asc" --fingerprint "$FPR" --now "$3" > /dev/null
	# what read-served.sh would write after reading this tree back
	PREV="$WORK/prev$N"
	mkdir -p "$PREV"
	D="$T/arch/x86_64"
	cp "$D/glyndor.db.tar.zst" "$D/glyndor.db.tar.zst.sig" "$PREV/"
	cp "$D/glyndor.state" "$PREV/state"
	cp "$D/glyndor.state.sig" "$PREV/state.sig"
	python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$D/glyndor.db.tar.zst" | awk -F'\t' '{ print $1 "\t" $2 "\t" $5 "\t" $3 }' > "$PREV/served.tsv"
}
sync() { # <previous dir> <now> [extra options]
	local prev="$1" at="$2"
	shift 2
	bash "$SCRIPT" --tree "$T" --previous "$prev" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --now "$at" "$@"
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
cleanup() { bash "$SCRIPT" --cleanup --tree "$T" --bucket glyndor-pacman --now "$1"; }
restore() { bash "$SCRIPT" --restore --previous "$1" --tree "${2:-$T}" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
puts() { grep -c '^put ' "$FAKE_LOG" || true; }
position() { grep -n -x -F -- "put arch/x86_64/$1" "$FAKE_LOG" | head -1 | cut -d: -f1; }
fresh_bucket() { rm -rf "$FAKE_BUCKET" "$FAKE_LOG"; mkdir -p "$FAKE_BUCKET"; : > "$FAKE_LOG"; unset FAKE_FAIL_KEY FAKE_FAIL_ONCE FAKE_HEAD_ERROR; }

echo "-- the first publication"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
printf 'KEY' > "$T/glyndor-pacman-key.asc"; printf '<html>' > "$T/index.html"; mkdir -p "$T/install"; printf '#!/bin/sh\n' > "$T/install/acme"
check "a tree is uploaded" "0" "$(rc_of sync "$WORK/first" "$T0")"
check "every package and its signature, both databases, the state and their signatures are in the bucket" "13" "$(find "$FAKE_BUCKET" -type f -not -path '*/.meta/*' | wc -l)"
check "the key, the page and the installer are there too" "3" "$(find "$FAKE_BUCKET" -maxdepth 2 -type f -not -path '*/.meta/*' \( -name glyndor-pacman-key.asc -o -name index.html -o -path '*/install/acme' \) | wc -l)"
check "the packages are written before the databases that name them" "yes" "$([ "$(position acme-1.2.2-1-x86_64.pkg.tar.zst)" -lt "$(position glyndor.db.tar.zst)" ] && [ "$(position lib-0.1.0-1-any.pkg.tar.zst.sig)" -lt "$(position glyndor.db.tar.zst)" ] && echo yes || echo no)"
check "the database group is the last six writes, in this order" \
	"put arch/x86_64/glyndor.db.tar.zst
put arch/x86_64/glyndor.db.tar.zst.sig
put arch/x86_64/glyndor.db
put arch/x86_64/glyndor.db.sig
put arch/x86_64/glyndor.state
put arch/x86_64/glyndor.state.sig" "$(tail -6 "$FAKE_LOG")"
check "each object keeps the sha256 of what was written" "$(sha256sum "$D/acme-1.2.2-1-x86_64.pkg.tar.zst" | cut -d' ' -f1)" "$(cat "$FAKE_BUCKET/.meta/arch_x86_64_acme-1.2.2-1-x86_64.pkg.tar.zst")"

echo "-- the second publication"
cp -r "$FAKE_BUCKET" "$WORK/bucket-v1"; : > "$FAKE_LOG"
V1PREV="$PREV"
signed "$WORK/pk2" "$V1PREV" "$T1"
check "a new version is uploaded over the first" "0" "$(rc_of sync "$V1PREV" "$T1")"
check "the package that is already there is not written again" "0" "$(grep -c 'lib-0.1.0-1-any.pkg.tar.zst' "$FAKE_LOG" || true)"
check "the new one is" "2" "$(grep -c 'acme-1.2.3-1-x86_64.pkg.tar.zst' "$FAKE_LOG" || true)"
check "the replaced package stays in the bucket while a signed database may still name it" "yes" "$([ -f "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst" ] && echo yes || echo no)"
check "and nothing is deleted" "0" "$(grep -c '^delete' "$FAKE_LOG" || true)"
V2PREV="$PREV"
signed "$WORK/pk2" "$V2PREV" "$T2"
check "a later publication, past the retention of the replaced package" "0" "$(rc_of sync "$V2PREV" "$T2")"
check "does not delete anything itself: the cleanup is a step of its own, after the read back" "0" "$(grep -c '^delete' "$FAKE_LOG" || true)"
check "the cleanup, past the retention, deletes nothing: a signed database a client still holds may name the package" "0 0" \
	"$(cleanup "$T2" > "$WORK/last.out" 2>&1; echo "$? $(grep -c '^delete' "$FAKE_LOG")")"
check "the replaced package and its signature are still in the bucket" "yes" \
	"$([ -f "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst" ] && [ -f "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst.sig" ] && echo yes || echo no)"
check "and the cleanup says which file it keeps and why" "1" "$(says 'retaining acme-1.2.2-1-x86_64.pkg.tar.zst: clients do not enforce')"
kept_bytes=$(($(stat -c %s "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst") + $(stat -c %s "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst.sig")))
check "and warns in the run how many files are kept and how many bytes with their signatures" "1" \
	"$(says "::warning::1 retired package file(s) are kept in the bucket, $kept_bytes bytes with their signatures (0 object(s) whose size could not be read)")"
rm "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst.sig"
check "a retired object whose size cannot be read is counted as such, and the cleanup still succeeds" "0 1" \
	"$(cleanup "$T2" > "$WORK/last.out" 2>&1; echo "$? $(says '(1 object(s) whose size could not be read)')")"
printf x > "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst.sig"
check "the current package is still there" "yes" "$([ -f "$FAKE_BUCKET/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst" ] && echo yes || echo no)"
# Weeks after its delete-after time, the file is still in the bucket and the publication of that day still counts it.
V3PREV="$PREV"; T3="2027-01-20T06:00:00Z"
signed "$WORK/pk2" "$V3PREV" "$T3"
check "a publication two months later" "0" "$(rc_of sync "$V3PREV" "$T3")"
kept_bytes=$(($(stat -c %s "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst") + $(stat -c %s "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst.sig")))
check "its cleanup still counts the package retired two months before, and its bytes" "0 1" \
	"$(cleanup "$T3" > "$WORK/last.out" 2>&1; echo "$? $(says "::warning::1 retired package file(s) are kept in the bucket, $kept_bytes bytes")")"

echo "-- refused before a byte is written"
rm -rf "$FAKE_BUCKET"; cp -r "$WORK/bucket-v1" "$FAKE_BUCKET"; : > "$FAKE_LOG"
signed "$WORK/pk2" "$V1PREV" "$T1"
printf x >> "$D/glyndor.db.tar.zst"
check "a database changed after it was signed" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "says that nothing is uploaded" "1" "$(says 'nothing is uploaded')"
check "and nothing was written" "0" "$(puts)"
signed "$WORK/pk2" "$V1PREV" "$T1"; printf x >> "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a package changed after it was signed" "5" "$(rc_of sync "$V1PREV" "$T1")"
signed "$WORK/pk2" "$V1PREV" "$T1"; printf x >> "$D/glyndor.db"
check "a glyndor.db that is not a copy of the signed one" "5" "$(rc_of sync "$V1PREV" "$T1")"
signed "$WORK/pk2" "$V1PREV" "$T1"; rm "$D/glyndor.state.sig"
check "a tree without a signature" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and nothing was written by any of them" "0" "$(puts)"
signed "$WORK/pk2" "$V1PREV" "$T1"
check "a state that has expired" "5" "$(rc_of sync "$V1PREV" 2027-01-01T00:00:00Z)"
check "a public key that is not the one that signed" "5" "$(make_gpg_key "$WORK/other"; rc_of bash "$SCRIPT" --tree "$T" --previous "$V1PREV" --public-key "$WORK/other/pub.asc" --bucket b --now "$T1")"
check "and nothing was written" "0" "$(puts)"

echo "-- a package that is in the bucket with other bytes"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
mkdir -p "$FAKE_BUCKET/arch/x86_64" "$FAKE_BUCKET/.meta"
printf 'other' > "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst"; printf '%064d\n' 0 > "$FAKE_BUCKET/.meta/arch_x86_64_lib-0.1.0-1-any.pkg.tar.zst"
check "is refused, before anything is written" "5" "$(rc_of sync "$WORK/first" "$T0")"
check "with the reason that bytes that change need a new version" "1" "$(says 'need a new version')"
check "and nothing was written, not a signature of a package that is there" "0" "$(puts)"
fresh_bucket; mkdir -p "$FAKE_BUCKET/arch/x86_64"; printf 'other' > "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst"
check "an object with no hash in its metadata is not trusted either" "5" "$(rc_of sync "$PREV" "$T0")"
fresh_bucket; export FAKE_HEAD_ERROR="An error occurred (403) when calling the HeadObject operation: Forbidden"
check "an error that is not 'not found' stops the run" "5" "$(rc_of sync "$PREV" "$T0")"
check "and nothing was written" "0" "$(puts)"

echo "-- a cut in the database group"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; V1PREV="$PREV"
sync "$WORK/first" "$T0" > /dev/null
cp "$FAKE_BUCKET/arch/x86_64/glyndor.db.tar.zst" "$WORK/db-v1"; cp "$FAKE_BUCKET/arch/x86_64/glyndor.state" "$WORK/state-v1"
signed "$WORK/pk2" "$V1PREV" "$T1"
export FAKE_FAIL_KEY="glyndor.state.sig" FAKE_FAIL_ONCE=1
check "a write of the group that fails makes the run fail" "1" "$(rc_of sync "$V1PREV" "$T1")"
check "and the previous database is put back" "0" "$(cmp "$FAKE_BUCKET/arch/x86_64/glyndor.db.tar.zst" "$WORK/db-v1" > /dev/null 2>&1; echo $?)"
check "and the previous state" "0" "$(cmp "$FAKE_BUCKET/arch/x86_64/glyndor.state" "$WORK/state-v1" > /dev/null 2>&1; echo $?)"
check "and glyndor.db is a copy of it" "0" "$(cmp "$FAKE_BUCKET/arch/x86_64/glyndor.db" "$WORK/db-v1" > /dev/null 2>&1; echo $?)"
check "the run says it was put back" "1" "$(says 'previous repository was put back')"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; V1PREV="$PREV"; sync "$WORK/first" "$T0" > /dev/null; signed "$WORK/pk2" "$V1PREV" "$T1"
export FAKE_FAIL_KEY="glyndor.db.sig"
unset FAKE_FAIL_ONCE
check "a cut that cannot be repaired still fails" "1" "$(rc_of sync "$V1PREV" "$T1")"
check "and says that the previous repository could not be put back" "1" "$(says 'could NOT be put back')"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; export FAKE_FAIL_KEY="glyndor.state" FAKE_FAIL_ONCE=1
check "a cut in a first publication fails" "1" "$(rc_of sync "$WORK/first" "$T0")"
check "and the databases it wrote are removed, so no half repository is served" "0" "$(find "$FAKE_BUCKET/arch/x86_64" -name 'glyndor.db*' | wc -l)"
check "the packages stay, they name nothing by themselves" "yes" "$([ -f "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst" ] && echo yes || echo no)"
fresh_bucket

echo "-- the state the bucket serves now is the one the run was built on, and the sequence goes up by one"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; V1PREV="$PREV"; V1T="$T"
sync "$WORK/first" "$T0" > /dev/null
signed "$WORK/pk2" "$V1PREV" "$T1"; : > "$FAKE_LOG"
cp "$FAKE_BUCKET/arch/x86_64/glyndor.state" "$WORK/live-good"
printf 'tampered' >> "$FAKE_BUCKET/arch/x86_64/glyndor.state"
check "a live state that is not the previous one is refused before any write" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and the message says that another publication or an older copy got there first" "1" "$(says 'is not the one this run was built on')"
check "and nothing was written" "0" "$(puts)"
cp "$WORK/live-good" "$FAKE_BUCKET/arch/x86_64/glyndor.state"
rm "$FAKE_BUCKET/arch/x86_64/glyndor.state"
check "a live state that is gone, when the run was built on one, is refused" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and says that the bucket has no state" "1" "$(says 'the bucket has no state')"
cp "$WORK/live-good" "$FAKE_BUCKET/arch/x86_64/glyndor.state"
cp "$V1T/arch/x86_64/glyndor.state.sig" "$WORK/sig-good"; printf 'not a signature' > "$FAKE_BUCKET/arch/x86_64/glyndor.state.sig"
check "a live state whose signature is not the previous one is refused" "5" "$(rc_of sync "$V1PREV" "$T1")"
cp "$WORK/sig-good" "$FAKE_BUCKET/arch/x86_64/glyndor.state.sig"
check "a first publication over a bucket that already has a state is refused" "5" "$(rc_of sync "$WORK/first" "$T1")"
signed "$WORK/pk1" "$WORK/first" "$T1"
check "a state of sequence 1 where the bucket serves 1 (it would go to 2) is refused" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and says which sequence it expected" "1" "$(says 'makes it 2')"
signed "$WORK/pk2" "$V1PREV" "$T1"
check "the right one, sequence 2 over a bucket that serves 1, is written" "0" "$(rc_of sync "$V1PREV" "$T1")"
V2PREV="$PREV"; V2T="$T"
check "the same publication again is refused: the bucket serves 2 now" "5" "$(rc_of sync "$V1PREV" "$T1")"
echo "-- a restore touches the bucket only when it holds the previous state or the one being written"
signed "$WORK/pk2" "$V1PREV" "$T1"; : > "$FAKE_LOG"
printf 'tampered' >> "$FAKE_BUCKET/arch/x86_64/glyndor.state"
check "a restore over a state that is neither is refused" "1" "$(rc_of restore "$V1PREV")"
check "and wrote nothing" "0" "$(puts)"
cp "$V2T/arch/x86_64/glyndor.state" "$FAKE_BUCKET/arch/x86_64/glyndor.state"; cp "$V2T/arch/x86_64/glyndor.state.sig" "$FAKE_BUCKET/arch/x86_64/glyndor.state.sig"
check "a restore over the state of the tree that was being written puts the previous one back" "0" "$(rc_of restore "$V1PREV" "$V2T")"
check "and the state is the previous one" "0" "$(cmp "$FAKE_BUCKET/arch/x86_64/glyndor.state" "$V1PREV/state" > /dev/null 2>&1; echo $?)"
check "a restore over the previous state itself is fine" "0" "$(rc_of restore "$V1PREV")"

echo "-- errors are told apart exactly, and immutable objects are written on a condition"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
for text in "An error occurred (404) when calling the GetObject operation: Not Found" "An error occurred (NoSuchKey) when calling the HeadObject operation: Not Found" \
	"404" "Not Found" "An error occurred (404) when calling the HeadObject operation: Not Found: the bucket does not exist"; do
	export FAKE_HEAD_ERROR="$text"
	check "the head answer '$text' is a hard failure, not 'no such object'" "5" "$(rc_of sync "$WORK/first" "$T0")"
done
unset FAKE_HEAD_ERROR
check "and nothing was written" "0" "$(puts)"
fresh_bucket; export FAKE_GET_ERROR="An error occurred (404) when calling the GetObject operation: Not Found"
check "the same for the read of the live state" "5" "$(rc_of sync "$WORK/first" "$T0")"
unset FAKE_GET_ERROR
fresh_bucket
check "the exact answer of a head of an object that is not there is 'no such object': the first publication goes through" "0" "$(rc_of sync "$WORK/first" "$T0")"
fresh_bucket; export FAKE_NO_COND_SUPPORT=1
check "a CLI with no --if-none-match still publishes" "0" "$(rc_of sync "$WORK/first" "$T0")"
check "and says that the head alone protects the immutable objects" "1" "$(says 'has no --if-none-match')"
unset FAKE_NO_COND_SUPPORT
at_v1() { fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; V1PREV="$PREV"; sync "$WORK/first" "$T0" > /dev/null; signed "$WORK/pk2" "$V1PREV" "$T1"; : > "$FAKE_LOG"; }
at_v1; rm -f "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst.sig"
check "a package that appears between the head and the write, with the same bytes, is left alone" "0" \
	"$(FAKE_HIDE_HEAD=lib-0.1.0-1-any.pkg.tar.zst FAKE_HIDE_COUNT=2 rc_of sync "$V1PREV" "$T1")"
check "and the one whose signature was missing got it" "yes" "$([ -f "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst.sig" ] && echo yes || echo no)"
check "the package itself was not written again" "0" "$(grep -c '^put arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst$' "$FAKE_LOG" || true)"
at_v1
printf 'other' > "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst"; printf '%064d\n' 0 > "$FAKE_BUCKET/.meta/arch_x86_64_lib-0.1.0-1-any.pkg.tar.zst"
check "a package that appears between the head and the write with other bytes is refused" "1" \
	"$(FAKE_HIDE_HEAD=lib-0.1.0-1-any.pkg.tar.zst FAKE_HIDE_COUNT=2 rc_of sync "$V1PREV" "$T1")"
check "and says that it appeared and is not the same bytes" "1" "$(says 'appeared in the bucket while it was being written')"

echo "-- the signature of a package is written before the package, and one that is missing is written even if the package is there"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
sync "$WORK/first" "$T0" > /dev/null
late=""
for f in acme-1.2.2-1-x86_64.pkg.tar.zst lib-0.1.0-1-any.pkg.tar.zst; do
	[ "$(position "$f.sig")" -lt "$(position "$f")" ] || late="$late $f"
done
check "each signature is written before its package" "" "$late"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; export FAKE_FAIL_KEY="acme-1.2.2-1-x86_64.pkg.tar.zst.sig"
check "a signature that cannot be written fails the run" "1" "$(rc_of sync "$WORK/first" "$T0")"
check "and its package was not written: it is never there without its signature" "no" "$([ -f "$FAKE_BUCKET/arch/x86_64/acme-1.2.2-1-x86_64.pkg.tar.zst" ] && echo yes || echo no)"
unset FAKE_FAIL_KEY
at_v1; rm "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst.sig"
check "a package that is there with no signature" "0" "$(rc_of sync "$V1PREV" "$T1")"
check "gets its signature and nothing else of the package is written" "put arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst.sig" "$(grep 'lib-0.1.0-1-any' "$FAKE_LOG")"

echo "-- the packages are the ones the signed database lists"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
cp "$WORK/pk2/acme-1.2.3-1-x86_64.pkg.tar.zst" "$D/"
gpg --homedir "$WORK/signhome" --batch --quiet --import "$WORK/key/secret.asc" 2> /dev/null || { mkdir -m 700 "$WORK/signhome"; gpg --homedir "$WORK/signhome" --batch --quiet --import "$WORK/key/secret.asc" 2> /dev/null; }
gpg --homedir "$WORK/signhome" --batch --yes --quiet --pinentry-mode loopback --passphrase '' --detach-sign --output "$D/acme-1.2.3-1-x86_64.pkg.tar.zst.sig" "$D/acme-1.2.3-1-x86_64.pkg.tar.zst"
gpgconf --homedir "$WORK/signhome" --kill all > /dev/null 2>&1 || true
gpgconf --homedir "$WORK/signhome" --remove-socketdir > /dev/null 2>&1 || true
check "a package with a good signature that the signed database does not list is refused" "5" "$(rc_of sync "$WORK/first" "$T0")"
check "and says so" "1" "$(says 'not the ones the signed database lists')"
check "and nothing was written" "0" "$(puts)"

echo "-- what is put back is verified first, in a publication and in a restore"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; V1PREV="$PREV"; V1T="$T"
sync "$WORK/first" "$T0" > /dev/null
signed "$WORK/pk2" "$V1PREV" "$T1"; : > "$FAKE_LOG"
prev_copy() { rm -rf "$WORK/pc"; cp -r "$V1PREV" "$WORK/pc"; }
prev_copy; printf 'x' >> "$WORK/pc/glyndor.db.tar.zst"
check "a previous database that was changed is refused before any write" "5" "$(rc_of sync "$WORK/pc" "$T1")"
check "and says that it does not verify" "1" "$(says 'previous repository does not verify')"
check "and nothing was written" "0" "$(puts)"
prev_copy; printf 'x' >> "$WORK/pc/state"
check "a previous state that was changed is refused" "5" "$(rc_of sync "$WORK/pc" "$T1")"
prev_copy; rm "$WORK/pc/state.sig"
check "a previous state with no signature is refused" "5" "$(rc_of sync "$WORK/pc" "$T1")"
prev_copy; cp "$V2T/arch/x86_64/glyndor.db.tar.zst" "$WORK/pc/glyndor.db.tar.zst"; cp "$V2T/arch/x86_64/glyndor.db.tar.zst.sig" "$WORK/pc/glyndor.db.tar.zst.sig"
check "a previous database that is signed but is not the one the previous state names is refused" "5" "$(rc_of sync "$WORK/pc" "$T1")"
check "and says so" "1" "$(says 'not the one the previous state names')"
check "a restore from a previous database that was changed is refused, and writes nothing" "5" "$(prev_copy; printf 'x' >> "$WORK/pc/glyndor.db.tar.zst"; rc_of restore "$WORK/pc" "$T")"
check "and so is one with a public key that did not sign it" "5" "$(make_gpg_key "$WORK/other2"; rc_of bash "$SCRIPT" --restore --previous "$V1PREV" --tree "$T" --public-key "$WORK/other2/pub.asc" --bucket glyndor-pacman)"
check "no write in any of them" "0" "$(puts)"
check "a restore from a sound previous repository is made" "0" "$(rc_of restore "$V1PREV" "$T")"

echo "-- what is already in the bucket under the name of a package is read back and verified"
at_v1
printf 'junk' > "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst.sig"
check "a signature in the bucket that does not verify the package is a hard failure, before any write" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and says which" "1" "$(says 'lib-0.1.0-1-any.pkg.tar.zst.sig in the bucket does not verify')"
check "and nothing was written" "0" "$(puts)"
at_v1
printf 'not the package' > "$FAKE_BUCKET/arch/x86_64/lib-0.1.0-1-any.pkg.tar.zst"
check "a package in the bucket whose bytes are not the ones to publish, with the metadata of the ones that are, is a hard failure" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and says that the metadata is not what counts" "1" "$(says 'whatever its metadata says')"
at_v1
check "a package and a signature in the bucket that are sound let the publication go on" "0" "$(rc_of sync "$V1PREV" "$T1")"

echo "-- a signature that is in the bucket without its package is read and verified too"
at_v1
printf 'junk' > "$FAKE_BUCKET/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"; printf '%064d\n' 0 > "$FAKE_BUCKET/.meta/arch_x86_64_acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "a planted signature with no package, which does not verify the package to publish, is a hard failure before any write" "5" "$(rc_of sync "$V1PREV" "$T1")"
check "and says which" "1" "$(says 'acme-1.2.3-1-x86_64.pkg.tar.zst.sig in the bucket does not verify')"
check "and nothing was written" "0" "$(puts)"
at_v1
cp "$D/lib-0.1.0-1-any.pkg.tar.zst.sig" "$FAKE_BUCKET/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"; printf '%064d\n' 0 > "$FAKE_BUCKET/.meta/arch_x86_64_acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "the signature of another package, planted under the name of this one, is refused" "5" "$(rc_of sync "$V1PREV" "$T1")"
at_v1
cp "$D/acme-1.2.3-1-x86_64.pkg.tar.zst.sig" "$FAKE_BUCKET/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"; printf '%064d\n' 0 > "$FAKE_BUCKET/.meta/arch_x86_64_acme-1.2.3-1-x86_64.pkg.tar.zst.sig"
check "the right signature left by an upload that stopped halfway is accepted, and the package is written" "0" "$(rc_of sync "$V1PREV" "$T1")"
at_v1
check "a signature that appears between the head and the write is read and verified too: a good one" "0" \
	"$(cp "$D/acme-1.2.3-1-x86_64.pkg.tar.zst.sig" "$FAKE_BUCKET/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"; FAKE_HIDE_HEAD=acme-1.2.3-1-x86_64.pkg.tar.zst.sig FAKE_HIDE_COUNT=1 rc_of sync "$V1PREV" "$T1")"
at_v1
check "and a bad one is refused" "1" "$(printf 'junk' > "$FAKE_BUCKET/arch/x86_64/acme-1.2.3-1-x86_64.pkg.tar.zst.sig"; FAKE_HIDE_HEAD=acme-1.2.3-1-x86_64.pkg.tar.zst.sig FAKE_HIDE_COUNT=2 rc_of sync "$V1PREV" "$T1")"

echo "-- the credentials and the options"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
check "no key id" "5" "$(AWS_ACCESS_KEY_ID="" rc_of sync "$PREV" "$T0")"
check "no endpoint" "5" "$(AWS_ENDPOINT_URL="" rc_of sync "$PREV" "$T0")"
check "an AWS CLI that does not read the endpoint from the environment" "5" "$(FAKE_AWS_VERSION=2.12.0 rc_of sync "$PREV" "$T0")"
check "an endpoint set for S3 alone, which would win" "5" "$(AWS_ENDPOINT_URL_S3=https://elsewhere.invalid rc_of sync "$PREV" "$T0")"
check "the setting that makes the CLI ignore the endpoint" "5" "$(AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true rc_of sync "$PREV" "$T0")"
check "an option that is not known" "2" "$(rc_of sync "$PREV" "$T0" --nope x)"
check "a missing option" "2" "$(rc_of bash "$SCRIPT" --tree "$T")"
check "none of these wrote anything" "0" "$(puts)"

finish
