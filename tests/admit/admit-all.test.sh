#!/usr/bin/env bash
#
# admit-all.sh: every product of the products file, and what happens to one that has nothing to
# admit. A product that has not published a package yet is skipped, which is how helmly and
# epistle-panel are ready before they ship; one that is already served and stops carrying its package
# stops the run, because the repository is rebuilt from what is admitted and would drop it in silence.
# An empty list of what is served is refused unless the run says it is the first publication.
#
# Requires: python3 with cryptography, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/admit/admit-all.sh"
KEYS="$WORK/keys"
new_key "$KEYS"
mkdir -p "$WORK"; : > "$WORK/none"
printf 'acme\trelease.yml\nlater\trelease.yml\nthird\trelease.yml\n' > "$WORK/signers.txt"
printf 'acme\tacme\tx86_64\t-\nlater\tlater\tx86_64|any\t-\nlater\tlater-extra\tany\t-\nthird\tthird\tx86_64\t-\n' > "$WORK/products.txt"
mkdir -p "$WORK/bin" "$WORK/releases"
cp "$FIXTURES/fake-gh" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export FAKE_RELEASES="$WORK/releases"
export FAKE_LOG="$WORK/gh.log"
N=0

# releases: acme and third carry a package, later carries none
releases() {
	N=$((N + 1))
	rm -rf "$FAKE_RELEASES"
	for repo in acme later third; do
		mkdir -p "$FAKE_RELEASES/$repo/v1.0.0"
		printf 'v1.0.0\n' > "$FAKE_RELEASES/$repo/LATEST"
	done
	add_pkg "$FAKE_RELEASES/acme/v1.0.0" "$KEYS" acme 1.0.0-1 x86_64
	add_pkg "$FAKE_RELEASES/third/v1.0.0" "$KEYS" third 1.0.0-1 x86_64
	printf x > "$FAKE_RELEASES/later/v1.0.0/later_1.0.0_amd64.deb"
}
admit() { # <served file> [options]
	local served="$1"
	shift
	rm -rf "$WORK/out$N"
	bash "$SCRIPT" --out "$WORK/out$N" --served "$served" --products "$WORK/products.txt" --ed25519-keys "$KEYS/release.b64" \
		--mldsa-keys "$WORK/none.b64" --pq-required "$WORK/none" --signers "$WORK/signers.txt" "$@"
}
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	# a traceback is a crash and never a verdict
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
says() { grep -c -- "$1" "$WORK/last.out" || true; }

# line <name> <pkgver> [sha256]: a line of the list of what is served, as read-served.sh writes it
line() { printf '%s\t%s\t%s\t%s-%s-x86_64.pkg.tar.zst\n' "$1" "$2" "${3:-$(printf '%064d' 0)}" "$1" "$2"; }
{ line acme 0.9.0-1; line third 0.9.0-1; } > "$WORK/served-two"
line acme 0.9.0-1 > "$WORK/served-one"
: > "$WORK/served-none"

releases
check "two products with packages and one without, none of it served: admitted" "0" "$(rc_of admit "$WORK/served-none" --first-publication)"
check "the fields of every package are kept in one file, for the signer" "acme-1.0.0-1-x86_64.pkg.tar.zst third-1.0.0-1-x86_64.pkg.tar.zst" "$(python3 -I -c 'import json,sys; print(*sorted(json.load(open(sys.argv[1]))))' "$WORK/out$N/pkginfo.json")"
check "the manifest has the two packages" "acme
third" "$(cut -f2 "$WORK/out$N/manifest.tsv")"
check "the product with nothing yet is skipped with a notice" "1" "$(says 'Glyndor/later has no pacman package yet and none is served')"
check "it is the products file's order" "acme
third" "$(cut -f1 "$WORK/out$N/manifest.tsv")"

releases
check "the same, with the packages already served" "0" "$(rc_of admit "$WORK/served-two")"

echo "-- a served product that stops carrying its package"
releases; rm -rf "$FAKE_RELEASES/third/v1.0.0"/*; printf x > "$FAKE_RELEASES/third/v1.0.0/third_1.0.0_amd64.deb"
check "is refused" "1" "$(rc_of admit "$WORK/served-two")"
check "and says which one" "1" "$(says 'third is served and the latest release of Glyndor/third carries no package')"
releases; rm -rf "$FAKE_RELEASES/third/v1.0.0"/*; printf x > "$FAKE_RELEASES/third/v1.0.0/third_1.0.0_amd64.deb"
{ line thirdparty 0.1.0-1; line acme 0.9.0-1; } > "$WORK/served-prefix"
check "a served name that only starts like it (thirdparty) does not count as it" "0" "$(rc_of admit "$WORK/served-prefix")"

echo "-- a package that the products file no longer declares leaves on purpose"
releases
{ line acme 0.9.0-1; line third 0.9.0-1; line gone 1.0.0-1; } > "$WORK/served-gone"
check "a served package nobody declares any more does not stop the run" "0" "$(rc_of admit "$WORK/served-gone")"
check "and the run says it leaves" "1" "$(says 'gone is served and no longer declared')"

echo "-- a version never goes backwards"
releases
check "a served version that is newer than the release is refused" "1" "$(line acme 1.0.1-1 > "$WORK/served-newer"; rc_of admit "$WORK/served-newer")"
check "and says that a version never goes backwards" "1" "$(says 'never goes backwards')"
check "newer by the revision of the same version" "1" "$(line acme 1.0.0+r2-1 > "$WORK/served-newer"; rc_of admit "$WORK/served-newer")"
check "1.10.0 is newer than a served 1.9.0, as numbers and not as text" "0" "$(rm -rf "$FAKE_RELEASES/acme/v1.0.0"; mkdir -p "$FAKE_RELEASES/acme/v1.10.0"; printf 'v1.10.0\n' > "$FAKE_RELEASES/acme/LATEST"; add_pkg "$FAKE_RELEASES/acme/v1.10.0" "$KEYS" acme 1.10.0-1 x86_64; { line acme 1.9.0-1; line third 0.9.0-1; } > "$WORK/served-text"; rc_of admit "$WORK/served-text")"
releases
check "the release 1.0.0 is not older than a served 0.10.0" "0" "$({ line acme 0.10.0-1; line third 0.10.0-1; } > "$WORK/served-ten"; rc_of admit "$WORK/served-ten")"
check "a served 1.0.0+r12 is newer than a release 1.0.0" "1" "$(line acme 1.0.0+r12-1 > "$WORK/served-r"; rc_of admit "$WORK/served-r")"
check "a served 1.0.0 is older than a release 1.0.0+r12 (the revision form is newer)" "0" "$(rm -rf "$FAKE_RELEASES/acme/v1.0.0" "$FAKE_RELEASES/acme/LATEST"; mkdir -p "$FAKE_RELEASES/acme/v1.0.0+r12"; printf 'v1.0.0+r12\n' > "$FAKE_RELEASES/acme/LATEST"; add_pkg "$FAKE_RELEASES/acme/v1.0.0+r12" "$KEYS" acme 1.0.0+r12-1 x86_64; { line acme 1.0.0-1; line third 0.9.0-1; } > "$WORK/served-r2"; rc_of admit "$WORK/served-r2")"

echo "-- the list of what is served is read strictly"
releases
served_with() { # <printf format and arguments>: a list with exactly those bytes
	# shellcheck disable=SC2059 # the caller gives the format
	printf "$@" > "$WORK/served-raw"
	rc_of admit "$WORK/served-raw"
}
good_line="$(line acme 0.9.0-1)"
check "a list with its last line cut (no final line feed) is refused" "1" "$(served_with '%s' "$good_line")"
check "and says that it does not end with a line feed" "1" "$(says 'does not end with a line feed')"
check "a line with only three fields" "1" "$(served_with 'acme\t0.9.0-1\t%064d\n' 0)"
check "a line with a sha256 that is not hexadecimal" "1" "$(served_with 'acme\t0.9.0-1\t%s\tacme-0.9.0-1-x86_64.pkg.tar.zst\n' "$(printf 'z%.0s' $(seq 1 64))")"
check "a sha256 of 63 digits" "1" "$(served_with 'acme\t0.9.0-1\t%s\tacme-0.9.0-1-x86_64.pkg.tar.zst\n' "$(printf '0%.0s' $(seq 1 63))")"
check "a version that is not X.Y.Z[+rN]-1" "1" "$(served_with 'acme\t1.0-1\t%064d\tacme-1.0-1-x86_64.pkg.tar.zst\n' 0)"
check "a file that is not the package's" "1" "$(served_with 'acme\t0.9.0-1\t%064d\tother-0.9.0-1-x86_64.pkg.tar.zst\n' 0)"
check "a line ended with a carriage return" "1" "$(served_with 'acme\t0.9.0-1\t%064d\tacme-0.9.0-1-x86_64.pkg.tar.zst\r\n' 0)"
check "a blank line" "1" "$(served_with '%s\n\n' "$good_line")"
check "a package listed twice" "1" "$(served_with '%s\n%s\n' "$good_line" "$good_line")"
check "a spurious space in place of a tab" "1" "$(served_with 'acme 0.9.0-1 %064d acme-0.9.0-1-x86_64.pkg.tar.zst\n' 0)"
check "a list of only a line feed is not an empty list that allows a first publication" "1" "$(served_with '\n' )"
check "a list that is not empty and valid is read" "0" "$(served_with '%s\n' "$good_line")"
check "an empty list is read as the first publication only when it says so" "0" "$(: > "$WORK/served-raw"; rc_of admit "$WORK/served-raw" --first-publication)"

echo "-- the list of what is served"
releases
check "an empty list without --first-publication is refused" "1" "$(rc_of admit "$WORK/served-none")"
check "and says why" "1" "$(says 'not the first publication')"
check "a list that is not there is a usage error" "2" "$(rc_of admit "$WORK/not-there")"
check "no list at all" "2" "$(rc_of bash "$SCRIPT" --out "$WORK/x")"
check "no product carries a package: refused even as the first publication" "1" \
	"$(rm -rf "$FAKE_RELEASES"/*/v1.0.0/*; for r in acme later third; do printf x > "$FAKE_RELEASES/$r/v1.0.0/${r}_1_amd64.deb"; done; rc_of admit "$WORK/served-none" --first-publication)"
check "and says that it will not publish an empty repository" "1" "$(says 'empty repository')"
check "a release that is refused stops the run" "1" "$(releases; add_pkg "$FAKE_RELEASES/acme/v1.0.0" "$KEYS" evil 1.0.0-1 x86_64; rc_of admit "$WORK/served-two")"
check "an option that is not known" "2" "$(releases; rc_of admit "$WORK/served-two" --nope x)"
check "an output folder that already holds a manifest" "2" "$(releases; mkdir -p "$WORK/out$N"; : > "$WORK/out$N/manifest.tsv"; rc_of bash "$SCRIPT" --out "$WORK/out$N" --served "$WORK/served-two" --products "$WORK/products.txt")"

echo "-- a published identity does not change bytes"
releases
hash_acme="$(sha256sum "$FAKE_RELEASES/acme/v1.0.0/acme-1.0.0-1-x86_64.pkg.tar.zst" | cut -d' ' -f1)"
hash_third="$(sha256sum "$FAKE_RELEASES/third/v1.0.0/third-1.0.0-1-x86_64.pkg.tar.zst" | cut -d' ' -f1)"
{ line acme 1.0.0-1 "$hash_acme"; line third 1.0.0-1 "$hash_third"; } > "$WORK/served-same"
check "the same name, version and hash is accepted" "0" "$(rc_of admit "$WORK/served-same")"
check "the same name and version with another hash is refused" "1" "$({ line acme 1.0.0-1; line third 1.0.0-1 "$hash_third"; } > "$WORK/served-diff"; rc_of admit "$WORK/served-diff")"
check "and says that bytes that change need a new version" "1" "$(says 'need a new version')"
check "another version served with another hash is not that identity" "0" "$({ line acme 0.9.0-1; line third 0.9.0-1; } > "$WORK/served-old"; rc_of admit "$WORK/served-old")"

finish
