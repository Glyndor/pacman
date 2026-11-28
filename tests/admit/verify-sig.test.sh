#!/usr/bin/env bash
#
# verify-sig.py: the release signature of one file, Ed25519 first and always, ML-DSA-65 beside it
# when it is there. The six cases of the post-quantum design are the ones below: a second signature
# that may be left out protects nothing, and one that cannot be checked is not one that passed. The
# three cases that need a real ML-DSA-65 implementation bring their own cryptography: a virtual
# environment is built here with the wheel that scripts/admit/verify-requirements.txt pins by hash,
# the same file .github/workflows/publish.yml installs. When it cannot be built the suite fails: a
# case that could not run is not a pass.
#
# Requires: python3 with cryptography, and a python3 that can build a virtual environment.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
VERIFY="$HERE/scripts/admit/verify-sig.py"
KEYS="$WORK/keys"
OTHER="$WORK/other"
new_key "$KEYS"
new_key "$OTHER"
printf 'a signed file\n' > "$WORK/file"
python3 -I "$FIXTURES/release-key.py" sign "$KEYS" "$WORK/file"
rc_of() {
	local rc=0
	"$@" > "$WORK/last.out" 2>&1 || rc=$?
	# a traceback is a crash and never a verdict
	if grep -q Traceback "$WORK/last.out"; then rc=99; fi
	echo "$rc"
}
verify() { python3 -I "$VERIFY" "$@"; }
# The cases that carry a second signature are checked with the cryptography that has
# ML-DSA-65: the one of the virtual environment built below. The Ed25519-only cases
# keep the system one.
verify_pq() { "$PQPY" -I "$VERIFY" "$@"; }
says() { grep -c -- "$1" "$WORK/last.out" || true; }

check "a signature by the listed key verifies" "0" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64")"
check "a signature by a key that is not listed is refused" "1" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$OTHER/release.b64")"
cat "$OTHER/release.b64" "$KEYS/release.b64" > "$WORK/both.b64"
check "any listed key may verify it (a rotation overlap)" "0" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/both.b64")"
{ echo "# a comment"; echo; cat "$KEYS/release.b64"; } > "$WORK/commented.b64"
check "comments and blank lines in the key file are ignored" "0" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/commented.b64")"
python3 -I "$FIXTURES/release-key.py" garbage "$WORK/bad.sig"
check "a signature that is not one is refused" "1" "$(rc_of verify "$WORK/file" "$WORK/bad.sig" "$KEYS/release.b64")"
head -c 63 "$WORK/file.sig" > "$WORK/short.sig"
check "a signature of 63 bytes is refused" "1" "$(rc_of verify "$WORK/file" "$WORK/short.sig" "$KEYS/release.b64")"
check "a signature that is not there is refused" "1" "$(rc_of verify "$WORK/file" "$WORK/none.sig" "$KEYS/release.b64")"
printf 'another file\n' > "$WORK/changed"
check "a signature of other bytes is refused" "1" "$(rc_of verify "$WORK/changed" "$WORK/file.sig" "$KEYS/release.b64")"
check "a file that is not there is refused" "1" "$(rc_of verify "$WORK/none" "$WORK/file.sig" "$KEYS/release.b64")"

echo "-- the key file is our own trust anchor, so a broken one is exit 2 and not a refusal"
check "a key file that is not there" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/none.b64")"
: > "$WORK/empty.b64"
check "a key file with no key" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/empty.b64")"
printf '%s\r\n' "$(cat "$KEYS/release.b64")" > "$WORK/crlf.b64"
check "a key file with a carriage return" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/crlf.b64")"
printf '\xef\xbb\xbf%s\n' "$(cat "$KEYS/release.b64")" > "$WORK/bom.b64"
check "a key file with a byte order mark" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/bom.b64")"
printf 'not*base64!\n' > "$WORK/nonb64.b64"
check "a key that is not base64" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/nonb64.b64")"
printf 'AAAA\n' > "$WORK/short.b64"
check "a key of the wrong length" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$WORK/short.b64")"
check "the committed release key is a key this verifier can read" "1" \
	"$(rc_of verify "$WORK/file" "$WORK/file.sig" "$HERE/keyring/glyndor-release-ed25519.b64")"
check "and it refuses the signature of the test key, as another key" "1" "$(says 'no release key verifies')"

echo "-- the second signature"
PQ="$WORK/second.sig"
check "no second signature and none required: accepted" "0" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ")"
check "and it says there was none" "1" "$(says 'no ML-DSA-65 signature, and none is required')"
check "no second signature and one required: refused" "1" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ" --require-mldsa)"
head -c 3309 /dev/zero > "$PQ"
check "a second signature and no key configured: refused" "1" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ")"
check "and it says that a signature that cannot be checked is refused" "1" "$(says 'refusing a signature that cannot be checked')"
python3 -I -c 'import base64;print(base64.b64encode(bytes(1952)).decode())' > "$WORK/pq.b64"
head -c 100 /dev/zero > "$PQ"
check "a second signature of the wrong length: refused" "1" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ" --mldsa-keys "$WORK/pq.b64")"
head -c 5000 /dev/zero > "$PQ"
check "a second signature over 4096 bytes: refused" "1" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ" --mldsa-keys "$WORK/pq.b64")"
rm -f "$PQ"; ln -s "$WORK/missing-target" "$PQ"
check "a second signature that is a dangling link counts as there, and is refused" "1" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ" --mldsa-keys "$WORK/pq.b64")"
rm -f "$PQ"; head -c 3309 /dev/zero > "$PQ"
printf 'AAAA\n' > "$WORK/pqshort.b64"
check "an ML-DSA key file with a key of the wrong length is exit 2" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$PQ" --mldsa-keys "$WORK/pqshort.b64")"
check "a bad Ed25519 signature is refused whatever the second one says" "1" "$(rc_of verify "$WORK/file" "$WORK/bad.sig" "$KEYS/release.b64" --mldsa-sig "$PQ" --mldsa-keys "$WORK/pq.b64")"
check "--require-mldsa without --mldsa-sig is a usage error" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --require-mldsa)"
check "--mldsa-keys without --mldsa-sig is a usage error" "2" "$(rc_of verify "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-keys "$WORK/pq.b64")"

# The three cases below need a cryptography with ML-DSA-65. The one of the runner
# does not have it, so a virtual environment is built here with the wheel that
# scripts/admit/verify-requirements.txt pins by hash, the same file
# .github/workflows/publish.yml installs. When it cannot be built the suite
# fails: a case that could not run is not a pass.
PQPY=""
if python3 -m venv "$WORK/venv" >/dev/null 2>&1 \
	&& "$WORK/venv/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes \
		--only-binary=:all: -r "$HERE/scripts/admit/verify-requirements.txt" >/dev/null 2>&1; then
	PQPY="$WORK/venv/bin/python"
fi
if [ -z "$PQPY" ] || ! "$PQPY" -I -c 'from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey' 2>/dev/null; then
	echo "FAIL  no cryptography with ML-DSA-65: install scripts/admit/verify-requirements.txt into a virtual environment"
	echo "0 passed, 1 failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" 0 1
	exit 1
fi
"$PQPY" -I - "$WORK" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey
work = sys.argv[1]
key = MLDSA65PrivateKey.generate()
data = open(f"{work}/file", "rb").read()
open(f"{work}/good.mldsa", "wb").write(key.sign(data))
pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
open(f"{work}/pq-real.b64", "w").write(base64.b64encode(pub).decode() + "\n")
open(f"{work}/other.mldsa", "wb").write(MLDSA65PrivateKey.generate().sign(data))
PY
check "both signatures valid: accepted" "0" "$(rc_of verify_pq "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$WORK/good.mldsa" --mldsa-keys "$WORK/pq-real.b64" --require-mldsa)"
check "a second signature by another key: refused" "1" "$(rc_of verify_pq "$WORK/file" "$WORK/file.sig" "$KEYS/release.b64" --mldsa-sig "$WORK/other.mldsa" --mldsa-keys "$WORK/pq-real.b64")"
check "a valid second signature does not rescue a bad Ed25519 one" "1" "$(rc_of verify_pq "$WORK/file" "$WORK/bad.sig" "$KEYS/release.b64" --mldsa-sig "$WORK/good.mldsa" --mldsa-keys "$WORK/pq-real.b64")"

finish
