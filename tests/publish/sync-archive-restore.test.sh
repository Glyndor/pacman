#!/usr/bin/env bash
#
# What a restore does with a database group that a publication left half written. The publication is killed after each
# of the six writes of the group, with nothing left to restore it itself, and another process puts it back from the
# previous repository and the signed tree. A mixture of those two is the only thing it writes over: any third content is
# refused with nothing written, and so is a tree that is not signed.
#
# Requires: gpg, python3, zstd, setsid.
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
mkdir -p "$WORK/bin" "$WORK/pk1" "$WORK/pk2" "$WORK/first"
cp "$FIXTURES/fake-aws" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export AWS_ACCESS_KEY_ID=id AWS_SECRET_ACCESS_KEY=secret AWS_ENDPOINT_URL=https://example.invalid
export FAKE_BUCKET="$WORK/bucket" FAKE_LOG="$WORK/log"
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk1/acme-1.2.2-1-x86_64.pkg.tar.zst" acme 1.2.2-1 x86_64
python3 -I "$FIXTURES/mkpkg.py" "$WORK/pk2/acme-1.2.3-1-x86_64.pkg.tar.zst" acme 1.2.3-1 x86_64
: > "$WORK/first/served.tsv"; : > "$WORK/first/no-state"
T0="2026-11-23T06:00:00Z"; T1="2026-11-24T06:00:00Z"
GROUP=(glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.db glyndor.db.sig glyndor.state glyndor.state.sig)
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
publish() { # <previous dir> <now>
	bash "$SCRIPT" --tree "$T" --previous "$1" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --now "$2"
}
restore() { # <previous dir> <tree> [--if-mixed]
	bash "$SCRIPT" --restore --previous "$1" --tree "$2" --public-key "$WORK/key/pub.asc" --bucket glyndor-pacman "${@:3}"
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
changes() { grep -c . "$FAKE_LOG" || true; }
fresh_bucket() { rm -rf "$FAKE_BUCKET" "$FAKE_LOG"; mkdir -p "$FAKE_BUCKET"; : > "$FAKE_LOG"; }
# whole <tree>: yes when the six objects of the bucket are those of the tree
whole() {
	local f
	for f in "${GROUP[@]}"; do
		cmp -s "$FAKE_BUCKET/arch/x86_64/$f" "$1/arch/x86_64/$f" || { echo no; return; }
	done
	echo yes
}
# cut_after <previous dir> <now> <name>: the publication of $T, killed once that object of arch/x86_64 is written
cut_after() {
	local rc=0
	# The braces keep the shell's own notice of a killed job out of the output.
	# shellcheck disable=SC2016 # $$ is the shell of the new session, which becomes the publication
	{ FAKE_DIE_AFTER="arch/x86_64/$3" setsid --wait bash -c 'FAKE_DIE_GROUP=$$ exec bash "$@"' cut "$SCRIPT" --tree "$T" --previous "$1" \
		--public-key "$WORK/key/pub.asc" --bucket glyndor-pacman --now "$2" > "$WORK/cut.out" 2>&1 || rc=$?; } 2> /dev/null
	check "the publication is killed after $3" "yes 0" "$([ "$rc" -ne 0 ] && echo yes || echo no) $(grep -c 'put back' "$WORK/cut.out" || true)"
}
# at_v1: a bucket that serves V1 ($V1T, $V1PREV), and V2 signed on it and not yet published ($T)
at_v1() {
	fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"; V1T="$T"; V1PREV="$PREV"
	publish "$WORK/first" "$T0" > /dev/null
	signed "$WORK/pk2" "$V1PREV" "$T1"; : > "$FAKE_LOG"
}

echo "-- a publication killed after each write of the database group"
for k in 0 1 2 3 4; do
	at_v1
	cut_after "$V1PREV" "$T1" "${GROUP[$k]}"
	# glyndor.db and its signature are copies of the first two, so every one of these cuts is a mixture.
	check "after write $((k + 1)) the bucket holds neither repository whole" "no no" "$(whole "$V1T") $(whole "$T")"
	: > "$FAKE_LOG"
	check "after write $((k + 1)) another process puts the previous repository back" "0" "$(rc_of restore "$V1PREV" "$T" --if-mixed)"
	check "after write $((k + 1)) the six objects are those of the previous repository" "yes" "$(whole "$V1T")"
	check "after write $((k + 1)) the next publication goes through" "0 yes" "$(rc_of publish "$V1PREV" "$T1") $(whole "$T")"
done
at_v1
cut_after "$V1PREV" "$T1" glyndor.state
check "a cut between the state and its signature leaves a state that its signature does not verify" "no no" "$(whole "$V1T") $(whole "$T")"
check "and the restore a failed read back calls puts it back too" "0 yes" "$(rc_of restore "$V1PREV" "$T") $(whole "$V1T")"
at_v1
cut_after "$V1PREV" "$T1" glyndor.state.sig
: > "$FAKE_LOG"
check "a publication killed after its last write left the new repository whole: it is not taken back" "0 0 yes" \
	"$(rc_of restore "$V1PREV" "$T" --if-mixed) $(changes) $(whole "$T")"
check "and the run says what the bucket holds" "1" "$(says 'holds the new database group whole')"
at_v1
check "a bucket that still serves the previous repository whole is not written" "0 0" "$(rc_of restore "$V1PREV" "$T" --if-mixed) $(changes)"
check "and the run says so" "1" "$(says 'holds the previous database group whole')"

echo "-- a third content is never written over"
for f in "${GROUP[@]}"; do
	at_v1
	cut_after "$V1PREV" "$T1" glyndor.db
	printf 'x' >> "$FAKE_BUCKET/arch/x86_64/$f"; : > "$FAKE_LOG"
	check "$f with other bytes: refused, nothing written" "1 0" "$(rc_of restore "$V1PREV" "$T" --if-mixed) $(changes)"
	check "$f with other bytes: named" "1" "$(says "$f in the bucket is neither")"
	check "$f with other bytes: the restore of a failed read back refuses it too" "1 0" "$(rc_of restore "$V1PREV" "$T") $(changes)"
done
at_v1
cut_after "$V1PREV" "$T1" glyndor.db
rm "$FAKE_BUCKET/arch/x86_64/glyndor.db.sig"; : > "$FAKE_LOG"
check "an object that is gone, where there was a previous one: refused" "1 0" "$(rc_of restore "$V1PREV" "$T" --if-mixed) $(changes)"
at_v1
cut_after "$V1PREV" "$T1" glyndor.db
# Another instant than V2: signed from the same inputs at the same one, the third state would be V2 itself.
V2T="$T"; signed "$WORK/pk2" "$V1PREV" "2026-11-24T06:00:01Z"; THIRD="$T"
cp "$THIRD/arch/x86_64/glyndor.state" "$FAKE_BUCKET/arch/x86_64/glyndor.state"
cp "$THIRD/arch/x86_64/glyndor.state.sig" "$FAKE_BUCKET/arch/x86_64/glyndor.state.sig"; : > "$FAKE_LOG"
check "a state signed by the repository that is of neither generation: refused" "1 0" \
	"$(rc_of restore "$V1PREV" "$V2T" --if-mixed) $(changes)"
at_v1
cut_after "$V1PREV" "$T1" glyndor.db
: > "$FAKE_LOG"
check "an object that cannot be read: refused" "1 0" \
	"$(FAKE_GET_ERROR='An error occurred (403) when calling the GetObject operation: Forbidden' rc_of restore "$V1PREV" "$T" --if-mixed) $(changes)"

echo "-- the tree is believed only when it is signed"
bad_tree() { # <description> <message>  with $WORK/bad made from $T by the caller
	check "$1: refused before any read of the bucket is used, nothing written" "5 0" "$(rc_of restore "$V1PREV" "$WORK/bad" --if-mixed) $(changes)"
	check "$1: says why" "1" "$(says "$2")"
}
at_v1
cut_after "$V1PREV" "$T1" glyndor.db
: > "$FAKE_LOG"
copy_tree() { rm -rf "$WORK/bad"; cp -r "$T" "$WORK/bad"; BAD="$WORK/bad/arch/x86_64"; }
copy_tree; printf x >> "$BAD/glyndor.db.tar.zst"
bad_tree "a database of the tree that was changed" "glyndor.db.tar.zst of the tree does not verify"
copy_tree; rm "$BAD/glyndor.state.sig"
bad_tree "a state of the tree with no signature" "glyndor.state of the tree does not verify"
copy_tree; printf x >> "$BAD/glyndor.db"
bad_tree "a glyndor.db of the tree that is not the signed one" "glyndor.db of the tree is not a copy"
copy_tree; printf x >> "$BAD/glyndor.db.sig"
bad_tree "a glyndor.db.sig of the tree that is not the signature" "glyndor.db of the tree is not a copy"
copy_tree
for f in glyndor.db.tar.zst glyndor.db.tar.zst.sig; do cp "$V1T/arch/x86_64/$f" "$BAD/$f"; done
cp "$V1T/arch/x86_64/glyndor.db.tar.zst" "$BAD/glyndor.db"; cp "$V1T/arch/x86_64/glyndor.db.tar.zst.sig" "$BAD/glyndor.db.sig"
bad_tree "a signed database of the tree that its state does not name" "the database of the tree is not the one its state names"

echo "-- a first publication that is killed"
fresh_bucket; signed "$WORK/pk1" "$WORK/first" "$T0"
cut_after "$WORK/first" "$T0" glyndor.db
: > "$FAKE_LOG"
check "what it wrote of the database group is removed" "0 0" \
	"$(rc_of restore "$WORK/first" "$T" --if-mixed) $(find "$FAKE_BUCKET/arch/x86_64" -name 'glyndor.[ds]*' | wc -l)"
check "and a first publication then goes through" "0 yes" "$(rc_of publish "$WORK/first" "$T0") $(whole "$T")"
: > "$FAKE_LOG"
check "a first publication that finished is not removed" "0 0 yes" "$(rc_of restore "$WORK/first" "$T" --if-mixed) $(changes) $(whole "$T")"
fresh_bucket; : > "$FAKE_LOG"
check "an empty bucket after no write at all is left as it is" "0 0" "$(rc_of restore "$WORK/first" "$T" --if-mixed) $(changes)"
fresh_bucket; mkdir -p "$FAKE_BUCKET/arch/x86_64"; printf 'other' > "$FAKE_BUCKET/arch/x86_64/glyndor.db"
check "an object of nobody in a first publication is refused" "1 0" "$(rc_of restore "$WORK/first" "$T" --if-mixed) $(changes)"

echo "-- the options"
check "--if-mixed with no restore" "2" "$(rc_of bash "$SCRIPT" --tree "$T" --previous "$V1PREV" --public-key "$WORK/key/pub.asc" --bucket b --if-mixed)"
check "--if-mixed with no tree" "2" "$(rc_of bash "$SCRIPT" --restore --previous "$V1PREV" --public-key "$WORK/key/pub.asc" --bucket b --if-mixed)"

finish
