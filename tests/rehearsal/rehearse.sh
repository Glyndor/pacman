#!/usr/bin/env bash
#
# Rehearse the whole publication, twice, with nothing real in it: a release key and a repository key made for the run,
# releases that a stand-in for `gh` serves from a folder, a bucket that is a folder behind a real HTTP server on the
# loopback, a stand-in for the Cloudflare API. No secret is read, nothing leaves the machine except what the Arch image
# downloads when it upgrades itself, and R2 is never touched.
#
#   rehearse.sh --out <dir> [--install] [--image pinned|current]
#
# Each round does what publish.yml does, with the same scripts in the same order: read what is served, admit the latest
# release of the product, add the keyring package, build the database in the pinned image, sign it, add the pages, upload,
# purge and read back. The first round is a first publication; the second publishes a newer version over it. With
# --install, an Arch container installs the first version with the installer (and the distribution's own podman already
# there), checks it, and upgrades to the second with `pacman -Syu`. The published tree and the logs are left in <dir>.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$HERE/tests/fixtures/pacman"
out="" install=no image=pinned
while [ "$#" -gt 0 ]; do
	case "$1" in
		--install) install=yes; shift; continue ;;
	esac
	[ "$#" -ge 2 ] || { echo "::error::rehearse.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--out) out="$2" ;;
		--image) image="$2" ;;
		*) echo "::error::rehearse.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
[ -n "$out" ] || { echo "::error::usage: rehearse.sh --out <dir> [--install] [--image pinned|current]" >&2; exit 2; }
[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 2; }
# shellcheck disable=SC1091 # the shared fixtures
. "$FIXTURES/lib.sh"
# shellcheck disable=SC1091 # the shared fixtures
. "$FIXTURES/repo.sh"
HOST="rehearsal-host-$$"
cleanup() {
	[ -z "${SERVER:-}" ] || kill "$SERVER" 2> /dev/null || true
	for engine in docker podman; do
		if command -v "$engine" > /dev/null; then "$engine" rmi -f "localhost/$HOST" > /dev/null 2>&1 || true; fi
	done
	rm -rf "$WORK"
}
trap cleanup EXIT

new_key "$WORK/release"
make_gpg_key "$WORK/gpg"
FPR="$(cat "$WORK/gpg/fpr")"
mkdir -p "$WORK/bin" "$WORK/site" "$WORK/state" "$WORK/rel/alpha"
cp "$FIXTURES/fake-gh" "$WORK/bin/gh"
cp "$FIXTURES/fake-aws" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export FAKE_RELEASES="$WORK/rel" FAKE_BUCKET="$WORK/site" FAKE_LOG="$WORK/aws.log"
export AWS_ACCESS_KEY_ID=rehearsal AWS_SECRET_ACCESS_KEY=rehearsal AWS_ENDPOINT_URL=https://rehearsal.invalid
printf 'alpha\talpha\tx86_64\t-\n' > "$WORK/products.txt"
printf 'alpha\trelease.yml\n' > "$WORK/signers.txt"
: > "$WORK/none"
for version in 1.0.0 1.1.0; do
	add_pkg "$WORK/rel/alpha/v$version" "$WORK/release" alpha "$version-1" x86_64 --member "usr/share/alpha/version=$version"
done
python3 -I "$FIXTURES/server.py" "$WORK/site" "$WORK/port" --state "$WORK/state" &
SERVER=$!
until [ -s "$WORK/port" ]; do sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$WORK/port")"
CF_API="$BASE"
export CF_API CF_ZONE=0123456789abcdef0123456789abcdef CF_TOKEN=rehearsal-token VERIFY_ATTEMPTS=3 VERIFY_DELAY=2

# round <n> <version> [--first-publication]: what publish.yml does, job by job, in this order
round() {
	local n="$1" version="$2"
	shift 2
	local dir="$WORK/round$n" now
	mkdir -p "$dir"
	printf 'v%s\n' "$version" > "$WORK/rel/alpha/LATEST"
	echo "== round $n: $version"
	# admit
	# the rehearsal publishes under its own key: nothing of it is recorded
	echo none > "$WORK/state-floor.txt"
	bash "$HERE/scripts/metadata/read-served.sh" --url "$BASE" --out "$dir/served" --key "$WORK/gpg/pub.asc" --floor "$WORK/state-floor.txt" "$@"
	bash "$HERE/scripts/admit/admit-all.sh" --out "$dir/admitted" --served "$dir/served/served.tsv" --products "$WORK/products.txt" \
		--ed25519-keys "$WORK/release/release.b64" --pq-required "$WORK/none" --signers "$WORK/signers.txt" --paths "$FIXTURES/paths-permissive.txt" "$@"
	bash "$HERE/scripts/keyring/make-keyring.sh" --admitted "$dir/admitted" --manifest "$dir/admitted/manifest.tsv" --pkginfo "$dir/admitted/pkginfo.json" --epoch 1700000000
	# build
	mkdir -p "$dir/build"
	cp -r "$dir/admitted" "$dir/build/admitted"
	cp "$dir/admitted/manifest.tsv" "$dir/build/manifest.tsv"
	cp "$dir/served/served.tsv" "$dir/build/served.tsv"
	cp "$HERE/scripts/assemble/floor.txt" "$dir/build/floor.txt"
	chmod -R a+rwX "$dir/build"
	bash "$HERE/scripts/assemble/run-in-arch.sh" scripts/assemble/stage-packages.sh "$dir/build" --admitted /work/admitted --manifest /work/manifest.tsv \
		--served /work/served.tsv --floor /work/floor.txt --out /work/tree
	# sign, with the key made for the run
	now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	GLYNDOR_PACMAN_GPG_PRIVATE_KEY="$(cat "$WORK/gpg/secret.asc")" bash "$HERE/scripts/sign/sign-tree.sh" --tree "$dir/build/tree" \
		--manifest "$dir/admitted/manifest.tsv" --pkginfo "$dir/admitted/pkginfo.json" --served "$dir/served" --public-key "$WORK/gpg/pub.asc" \
		--fingerprint "$FPR" --now "$now"
	# publish: the pages are built in a folder of their own, not in what the signer left
	mkdir "$dir/pages"
	cp "$WORK/gpg/pub.asc" "$dir/pages/glyndor-pacman-key.asc"
	bash "$HERE/scripts/pages/build-index-page.sh" "$dir/build/tree/arch/x86_64/glyndor.db.tar.zst" "$dir/pages/index.html"
	names="$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$dir/build/tree/arch/x86_64/glyndor.db.tar.zst" | cut -f1)"
	# shellcheck disable=SC2086
	bash "$HERE/scripts/pages/build-installers.sh" "$dir/pages/install" $names
	bash "$HERE/scripts/publish/publish.sh" --tree "$dir/build/tree" --pages "$dir/pages" --previous "$dir/served" --public-key "$WORK/gpg/pub.asc" --bucket rehearsal --url "$BASE" --now "$now"
}

round 1 1.0.0 --first-publication
if [ "$install" = yes ]; then
	bash "$HERE/scripts/verify/run-live.sh" install --image "$image" --state "$HOST" --network host --base "$BASE" --fpr "$FPR" \
		--package alpha --expect 1.0.0-1 --distro podman --run 'test "$(cat /usr/share/alpha/version)" = 1.0.0'
fi
round 2 1.1.0
if [ "$install" = yes ]; then
	bash "$HERE/scripts/verify/run-live.sh" upgrade --state "$HOST" --network host --package alpha --expect 1.1.0-1 \
		--run 'test "$(cat /usr/share/alpha/version)" = 1.1.0'
fi
check "the keyring package is in the repository, with the same bytes in both rounds" "$(sha256sum "$WORK/round1/admitted/glyndor/"*.pkg.tar.zst | cut -d' ' -f1)" \
	"$(sha256sum "$WORK/round2/admitted/glyndor/"*.pkg.tar.zst | cut -d' ' -f1)"
check "the second publication is sequence 2" "2" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$WORK/site/arch/x86_64/glyndor.state" sequence)"
check "the first version of alpha is retired by the second" "alpha-1.0.0-1-x86_64.pkg.tar.zst" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$WORK/site/arch/x86_64/glyndor.state" retired | cut -d' ' -f1)"
mkdir -p "$out"
cp -r "$WORK/site" "$out/tree"
rm -rf "$out/tree/.meta"
cp "$WORK/aws.log" "$out/aws.log"
finish
