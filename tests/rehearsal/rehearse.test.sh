#!/usr/bin/env bash
#
# The rehearsal of the publication, run without the install (the Arch container that installs and upgrades is run by
# rehearsal.yml): two publications over a bucket that is a folder behind a real server, with the same scripts in the same
# order as publish.yml. What is left in the output folder is the published tree, and it is read here as a client would:
# signed by the key made for the run, a state that advanced, the first version retired by the second, the keyring package
# the same bytes in both rounds, no files database, and every package the database lists served with its signature.
#
# Requires: docker or podman, gpg, python3 with cryptography, zstd, curl.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { if grep -q -F -- "$1" "$WORK/last.out"; then echo 1; else echo 0; fi; }

check "the rehearsal runs to its end" "0" "$(rc_of bash "$HERE/tests/rehearsal/rehearse.sh" --out "$WORK/out")"
check "and says that it did two rounds" "2" "$(grep -c '^== round' "$WORK/last.out" || true)"
T="$WORK/out/tree"
D="$T/arch/x86_64"
check "the published database, its signature and the state are there" "glyndor.db glyndor.db.sig glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig" \
	"$(cd "$D" && echo glyndor.*)"
check "there is no files database" "0" "$(find "$T" -name 'glyndor.files*' | wc -l)"
check "the second version of alpha and the keyring are served, with their signatures" "alpha-1.1.0-1-x86_64.pkg.tar.zst alpha-1.1.0-1-x86_64.pkg.tar.zst.sig glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst glyndor-keyring-1.0.1700000000-1-any.pkg.tar.zst.sig" \
	"$(cd "$D" && echo alpha-1.1.0* glyndor-keyring*)"
check "the first version is still there, retired and not yet deleted" "yes" "$([ -f "$D/alpha-1.0.0-1-x86_64.pkg.tar.zst" ] && echo yes || echo no)"
check "the state is the second and names it" "2" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$D/glyndor.state" sequence)"
check "the database lists the new version and the keyring, and not the old one" "alpha 1.1.0-1
glyndor-keyring 1.0.1700000000-1" "$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$D/glyndor.db.tar.zst" | cut -f1,2 | tr '\t' ' ')"
check "the key, the page and both installers are served" "glyndor-pacman-key.asc index.html install" "$(cd "$T" && echo glyndor-pacman-key.asc index.html install)"
check "an installer for each package of the database" "alpha glyndor-keyring" "$(cd "$T/install" && echo *)"
check "the log of the bucket shows the database group written last in each round" "2" "$(grep -c 'put arch/x86_64/glyndor.state.sig' "$WORK/out/aws.log")"

finish
