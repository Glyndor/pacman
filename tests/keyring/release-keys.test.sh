#!/usr/bin/env bash
#
# keyring/ holds the trust anchors the admission checks a release against, and nothing else reads
# them as data: a key replaced by another, a key file with a stray byte, an ML-DSA key or a required
# product that appears without anybody deciding it would all be a text file that every other check
# ignores. This pins the state as decided: the release key is the one every Glyndor channel trusts,
# and the second signature is off (no ML-DSA key, no product that requires it).
#
# Turning the second signature on is a decision of the owner and a commit that changes this file
# with it, which is the point of pinning it.
#
# Requires: python3 with cryptography.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
RELEASE_KEY="HFv7vg5FCY7YyKUDbJhaQSfB9SboJGSblJtFbLmLHzM"
keys() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" || true; }

check "the release key is the one every Glyndor channel and updater trusts" "$RELEASE_KEY" "$(keys "$HERE/keyring/glyndor-release-ed25519.b64")"
check "and it is a 32-byte Ed25519 public key" "32" "$(keys "$HERE/keyring/glyndor-release-ed25519.b64" | python3 -I -c 'import base64,sys; s=sys.stdin.read().strip(); print(len(base64.b64decode(s + "=" * (-len(s) % 4), validate=True)))')"
check "the release key file is printable ASCII and line feeds only" "0" "$(LC_ALL=C tr -d ' -~\n' < "$HERE/keyring/glyndor-release-ed25519.b64" | wc -c)"
check "no ML-DSA-65 key is configured (the second signature is off)" "" "$(keys "$HERE/keyring/glyndor-release-mldsa65.b64")"
check "no package requires the second signature yet" "" "$(keys "$HERE/keyring/pq-required-products")"
check "the ML-DSA key file is printable ASCII and line feeds only" "0" "$(LC_ALL=C tr -d ' -~\n' < "$HERE/keyring/glyndor-release-mldsa65.b64" | wc -c)"
check "the required list is printable ASCII and line feeds only" "0" "$(LC_ALL=C tr -d ' -~\n' < "$HERE/keyring/pq-required-products" | wc -c)"

finish
