# shellcheck shell=bash
# Shared by the suites that build a release out of tiny packages. Source it, do not run it.
#
# A suite sets HERE (the repository root) before sourcing. It gets: WORK, a scratch folder removed
# on exit; check and finish, the counters every suite prints; new_key, a throwaway release key;
# add_pkg, a signed package placed in a folder that stands for a release.

FIXTURES="$HERE/tests/fixtures/pacman"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

finish() {
	echo "$pass passed, $fail failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[1]##*/}" "$pass" "$fail"
	[ "$fail" -eq 0 ]
}

new_key() { # <dir>: release.seed and release.b64 in it
	mkdir -p "$1"
	python3 -I "$FIXTURES/release-key.py" new "$1"
}

# add_pkg <release folder> <key dir> <name> <pkgver> <arch> [mkpkg option...]
# Builds <name>-<pkgver>-<arch>.pkg.tar.zst in the folder and signs it with the key.
add_pkg() {
	local folder="$1" keys="$2" name="$3" pkgver="$4" arch="$5"
	shift 5
	mkdir -p "$folder"
	python3 -I "$FIXTURES/mkpkg.py" "$folder/$name-$pkgver-$arch.pkg.tar.zst" "$name" "$pkgver" "$arch" "$@"
	python3 -I "$FIXTURES/release-key.py" sign "$keys" "$folder/$name-$pkgver-$arch.pkg.tar.zst"
}

# listing <folder>: what `gh release view --json assets` would say about it
listing() {
	FAKE_RELEASES="$(dirname "$(dirname "$1")")" FAKE_DIGEST="${FAKE_DIGEST:-0}" \
		bash "$FIXTURES/fake-gh" release view "$(basename "$1")" --repo "Glyndor/$(basename "$(dirname "$1")")" --json assets
}
