#!/usr/bin/env bash
#
# admit-product.sh: resolve the latest release of one repository once, fetch exactly the files the
# plan names, verify them and check their provenance. gh is a stand-in that serves releases from a
# folder (tests/fixtures/pacman/fake-gh) and writes down every call it gets, so the tests can say what
# was and what was not transferred: a release that is refused must be refused before a byte of it
# is downloaded, and a download must name the tag it resolved and not "latest" again.
#
# Requires: python3 with cryptography, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/admit/admit-product.sh"
KEYS="$WORK/keys"
new_key "$KEYS"
printf 'acme\tacme\tx86_64\t-\n' > "$WORK/products.txt"
printf 'acme\trelease.yml\n' > "$WORK/signers.txt"
: > "$WORK/none"
mkdir -p "$WORK/bin"
cp "$FIXTURES/fake-gh" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export FAKE_RELEASES="$WORK/releases"
export FAKE_LOG="$WORK/gh.log"
N=0
P="acme-1.2.3-1-x86_64.pkg.tar.zst"

# release: a repository acme whose latest release is v1.2.3 and holds the good package
release() {
	N=$((N + 1))
	rm -rf "$FAKE_RELEASES"
	mkdir -p "$FAKE_RELEASES/acme/v1.2.3"
	printf 'v1.2.3\n' > "$FAKE_RELEASES/acme/LATEST"
	add_pkg "$FAKE_RELEASES/acme/v1.2.3" "$KEYS" acme 1.2.3-1 x86_64 "$@"
}
admit() { # [extra options]
	: > "$FAKE_LOG"
	rm -rf "$WORK/out$N"
	bash "$SCRIPT" --repo acme --out "$WORK/out$N" --products "$WORK/products.txt" --ed25519-keys "$KEYS/release.b64" \
		--mldsa-keys "$WORK/none.b64" --pq-required "$WORK/none" --signers "$WORK/signers.txt" "$@"
}
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	# a traceback is a crash and never a verdict
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
calls() { grep -c -- "$1" "$FAKE_LOG" || true; }

release
check "the latest release is admitted" "0" "$(rc_of admit)"
check "the package is in <out>/<repo>/ with its signature" "$P
$P.sig" "$(ls "$WORK/out$N/acme")"
check "the manifest lists it" "1" "$(wc -l < "$WORK/out$N/acme.manifest")"
check "the tag it admitted is written down" "acme	v1.2.3" "$(cat "$WORK/out$N/acme.tag")"
check "the downloads name the tag that was resolved, not 'latest'" "2" "$(calls 'release download v1.2.3 ')"
check "each download names one exact file" "2" "$(grep -c -- "--pattern acme-1.2.3-1-x86_64.pkg.tar.zst" "$FAKE_LOG" || true)"
check "the provenance of the package is checked against its own repository" "1" "$(calls 'attestation verify .*acme-1.2.3-1-x86_64.pkg.tar.zst --repo Glyndor/acme')"
check "the attestation is tied to the tag, to the commit the tag points at and to hosted runners" "1" \
	"$(calls "attestation verify .*acme-1.2.3-1-x86_64.pkg.tar.zst --repo Glyndor/acme --source-ref refs/tags/v1.2.3 --signer-workflow Glyndor/acme/.github/workflows/release.yml --source-digest $(printf 'acme/v1.2.3' | sha1sum | cut -d' ' -f1) --deny-self-hosted-runners")"
check "the latest release was asked once" "1" "$(calls 'release view --repo Glyndor/acme --json tagName')"

echo "-- refused before anything is downloaded"
release; add_pkg "$FAKE_RELEASES/acme/v1.2.3" "$KEYS" evil 1.2.3-1 x86_64
check "a second package in the release" "1" "$(rc_of admit)"
check "and nothing was downloaded" "0" "$(calls 'release download')"
release; rm "$FAKE_RELEASES/acme/v1.2.3/$P.sig"
check "a package with no signature" "1" "$(rc_of admit)"
check "and nothing was downloaded" "0" "$(calls 'release download')"
release; printf '*\n' > "$FAKE_RELEASES/acme/v1.2.3/ok.txt"; cp "$FAKE_RELEASES/acme/v1.2.3/$P" "$FAKE_RELEASES/acme/v1.2.3/*.pkg.tar.zst"
check "a package-like asset whose name is a glob" "1" "$(rc_of admit)"
check "and nothing was downloaded" "0" "$(calls 'release download')"

echo "-- refused after"
release
check "an attestation made for another release of the same product is refused" "1" "$(FAKE_ATTEST_TAG=v1.2.2 rc_of admit)"
check "and the message names the tag and the commit" "1" "$(grep -c 'for v1.2.3 at' "$WORK/last.out" || true)"
check "an attestation made by another workflow of the repository is refused" "1" "$(FAKE_ATTEST_WORKFLOW=Glyndor/acme/.github/workflows/test.yml rc_of admit)"
check "a repository with no signing workflow listed stops the admission" "2" "$(printf 'other\trelease.yml\n' > "$WORK/signers-none.txt"; rc_of admit --signers "$WORK/signers-none.txt")"
check "an attestation of another commit than the tag's is refused" "1" "$(FAKE_ATTEST_DIGEST=0000000000000000000000000000000000000000 rc_of admit)"
check "a tag whose commit cannot be resolved is refused" "1" "$(FAKE_COMMIT=not-a-sha rc_of admit)"
release; python3 -I "$FIXTURES/release-key.py" garbage "$FAKE_RELEASES/acme/v1.2.3/$P.sig"
check "a signature that is not the release key's" "1" "$(rc_of admit)"
release --set packager="Somebody <x@example.org>"
check "a package of another vendor" "1" "$(rc_of admit)"
release
check "a package without provenance is refused" "1" "$(FAKE_NO_ATTEST="$P" rc_of admit)"
check "and the message names the file" "1" "$(grep -c "$P has no provenance" "$WORK/last.out" || true)"

echo "-- the latest release carries no package"
release; rm "$FAKE_RELEASES/acme/v1.2.3/$P" "$FAKE_RELEASES/acme/v1.2.3/$P.sig"; printf x > "$FAKE_RELEASES/acme/v1.2.3/acme_1.2.3_amd64.deb"
check "is reported as such (status 10), not as a refusal" "10" "$(rc_of admit)"
check "and nothing was downloaded" "0" "$(calls 'release download')"

echo "-- the places and the options"
release
check "a repository that does not exist" "1" "$(rc_of admit --repo nobody)"
check "a repository name with a path" "2" "$(rc_of admit --repo ../etc)"
check "an option that is not known" "2" "$(rc_of admit --nope x)"
check "an option with no value" "2" "$(rc_of bash "$SCRIPT" --repo)"
check "no repository" "2" "$(rc_of bash "$SCRIPT" --out "$WORK/x")"
mkdir -p "$WORK/out$N/acme"
check "a destination that already exists is not reused" "2" "$(rc_of bash "$SCRIPT" --repo acme --out "$WORK/out$N" --products "$WORK/products.txt" --ed25519-keys "$KEYS/release.b64")"
release; rm -f "$FAKE_RELEASES/acme/LATEST"
check "a latest release that cannot be resolved" "1" "$(rc_of admit)"
check "the repository's own key files are used when none is given" "1" "$(rc_of bash "$SCRIPT" --repo acme --out "$WORK/default$N" --products "$WORK/products.txt")"

finish
