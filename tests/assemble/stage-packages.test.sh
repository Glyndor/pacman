#!/usr/bin/env bash
#
# stage-packages.sh, in the real Arch image (the digest of arch-image.txt, with the pacman it ships, no
# network): the admitted packages are staged for signing, and a package is refused when
# vercmp says it is older than the one served or when it is the same version with other bytes. The version
# cases that matter to the contract are run through the real vercmp: 6.2.0 < 6.2.0+r12 < 6.2.1, which is why
# the Podman packages are numbered as they are.
#
# This suite needs docker or podman, and does not pretend otherwise: without one it fails.
# Requires: docker or podman, python3, zstd.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
RUN="$HERE/scripts/assemble/run-in-arch.sh"
mkdir -p "$WORK/w/admitted/r"
chmod -R a+rwX "$WORK/w"
add() { python3 -I "$FIXTURES/mkpkg.py" "$WORK/w/admitted/r/$1-$2-$3.pkg.tar.zst" "$1" "$2" "$3" "${@:4}"; }
manifest() { # <package>...: one manifest row per file in admitted/r given by name
	: > "$WORK/w/manifest.tsv"
	local f name rest version arch
	for f in "$@"; do
		name="${f%%-[0-9]*}"
		rest="${f#"$name"-}"
		arch="${rest%.pkg.tar.zst}"
		arch="${arch##*-}"
		version="${rest%-"$arch".pkg.tar.zst}"
		printf 'r\t%s\t%s\t%s\t%s\t%s\t%s\tno\n' "$name" "$version" "$arch" "$f" "$(stat -c%s "$WORK/w/admitted/r/$f")" \
			"$(sha256sum "$WORK/w/admitted/r/$f" | cut -d' ' -f1)" >> "$WORK/w/manifest.tsv"
	done
}
build() { # <served tsv>: builds into w/out
	rm -rf "$WORK/w/out"
	cp "$1" "$WORK/w/served.tsv"
	chmod a+r "$WORK/w/served.tsv" "$WORK/w/manifest.tsv"
	bash "$RUN" scripts/assemble/stage-packages.sh "$WORK/w" --admitted /work/admitted --manifest /work/manifest.tsv --served /work/served.tsv --floor /work/floor.txt --out /work/out
}
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }
: > "$WORK/none.tsv"
: > "$WORK/w/floor.txt"

add acme 1.2.3-1 x86_64
add lib 0.1-1 any
manifest acme-1.2.3-1-x86_64.pkg.tar.zst lib-0.1-1-any.pkg.tar.zst
check "the admitted packages are staged" "0" "$(rc_of build "$WORK/none.tsv")"
T="$WORK/w/out/arch/x86_64"
check "nothing in the staged tree is writable by the group or by others" "0" "$(find "$WORK/w/out" -perm /022 ! -type l | wc -l)"
check "and it all belongs to the user who started the container" "0" "$(find "$WORK/w/out" ! -user "$(id -un)" | wc -l)"
check "the tree holds the packages and nothing else: no database, not even the one repo-add would write" \
	"acme-1.2.3-1-x86_64.pkg.tar.zst lib-0.1-1-any.pkg.tar.zst" "$(cd "$T" && echo *)"
check "the packages are the admitted bytes" "0" "$(cmp "$T/acme-1.2.3-1-x86_64.pkg.tar.zst" "$WORK/w/admitted/r/acme-1.2.3-1-x86_64.pkg.tar.zst" > /dev/null 2>&1; echo $?)"
check "and regular files, not links" "2" "$(find "$T" -type f | wc -l)"

echo "-- vercmp decides"
served() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$1-$2-x86_64.pkg.tar.zst" > "$WORK/served-one.tsv"; }
rm -f "$WORK/w/admitted/r/"*; add acme 6.2.0+r12-1 x86_64; manifest acme-6.2.0+r12-1-x86_64.pkg.tar.zst
served acme 6.2.0-1 0
check "6.2.0+r12 replaces a served 6.2.0 (a revision of the same version is newer)" "0" "$(rc_of build "$WORK/served-one.tsv")"
served acme 6.2.0-3 0
check "and a served 6.2.0 whatever its pkgrel" "0" "$(rc_of build "$WORK/served-one.tsv")"
served acme 6.2.1-1 0
check "6.2.0+r12 does not replace a served 6.2.1" "1" "$(rc_of build "$WORK/served-one.tsv")"
check "and the message says that a version never goes backwards" "1" "$(says 'never goes backwards')"
served acme 6.2.0+r13-1 0
check "nor a served 6.2.0+r13" "1" "$(rc_of build "$WORK/served-one.tsv")"
served acme 6.2.0+r12-1 0000000000000000000000000000000000000000000000000000000000000000
check "the same version with other bytes is refused" "1" "$(rc_of build "$WORK/served-one.tsv")"
check "and the message says that a new build needs a new version" "1" "$(says 'needs a new version')"
served acme 6.2.0+r12-1 "$(sha256sum "$WORK/w/admitted/r/acme-6.2.0+r12-1-x86_64.pkg.tar.zst" | cut -d' ' -f1)"
check "the same version with the same bytes is accepted" "0" "$(rc_of build "$WORK/served-one.tsv")"
served other 9-1 0
check "another package served does not matter" "0" "$(rc_of build "$WORK/served-one.tsv")"

echo "-- the floor"
rm -f "$WORK/w/admitted/r/"*; add acme 1.0-1 x86_64; manifest acme-1.0-1-x86_64.pkg.tar.zst
printf '# a record\nacme\t1.0-1\n' > "$WORK/w/floor.txt"
check "a package at its floor is accepted" "0" "$(rc_of build "$WORK/none.tsv")"
printf 'acme\t1.0-2\n' > "$WORK/w/floor.txt"
check "a package below its floor is refused even when nothing is served" "1" "$(rc_of build "$WORK/none.tsv")"
check "and says that it is below the floor" "1" "$(says 'below the floor')"
printf 'other\t9-1\n' > "$WORK/w/floor.txt"
check "the floor of another package does not apply" "0" "$(rc_of build "$WORK/none.tsv")"
printf 'acme 1.0-1\n' > "$WORK/w/floor.txt"
check "a floor line without a tab is a configuration error, not a skipped line" "2" "$(rc_of build "$WORK/none.tsv")"
printf 'acme\t1.0-1\textra\n' > "$WORK/w/floor.txt"
check "a floor line with a third field is a configuration error" "2" "$(rc_of build "$WORK/none.tsv")"
check "a floor file that is not there is a configuration error" "2" "$(rm "$WORK/w/floor.txt"; rc_of build "$WORK/none.tsv")"
: > "$WORK/w/floor.txt"
check "the floor file of the repository is well formed" "0" "$(grep -c -v -e '^#' -e '^$' "$HERE/scripts/assemble/floor.txt" || true)"

echo "-- what is refused"
check "a manifest that is empty" "1" "$(: > "$WORK/w/manifest.tsv"; rc_of build "$WORK/none.tsv")"
manifest acme-6.2.0+r12-1-x86_64.pkg.tar.zst
printf x >> "$WORK/w/admitted/r/acme-6.2.0+r12-1-x86_64.pkg.tar.zst"
check "a package that is not the admitted bytes" "1" "$(rc_of build "$WORK/none.tsv")"
rm -f "$WORK/w/admitted/r/"*; add acme 1.0-1 x86_64; manifest acme-1.0-1-x86_64.pkg.tar.zst
rm "$WORK/w/admitted/r/acme-1.0-1-x86_64.pkg.tar.zst"; ln -s /etc/hostname "$WORK/w/admitted/r/acme-1.0-1-x86_64.pkg.tar.zst"
check "a package that is a symbolic link" "1" "$(rc_of build "$WORK/none.tsv")"
rm "$WORK/w/admitted/r/acme-1.0-1-x86_64.pkg.tar.zst"; add acme 1.0-1 x86_64
check "an output folder that exists" "2" "$(mkdir -p "$WORK/w/there"; rc_of bash "$RUN" scripts/assemble/stage-packages.sh "$WORK/w" --admitted /work/admitted --manifest /work/manifest.tsv --served /work/served.tsv --out /work/there)"
check "an option that is not known" "2" "$(rc_of bash "$RUN" scripts/assemble/stage-packages.sh "$WORK/w" --nope x)"
check "a missing option" "2" "$(rc_of bash "$RUN" scripts/assemble/stage-packages.sh "$WORK/w" --out /work/y)"

echo "-- the tool that decides is checked before anything is judged"
mkdir -p "$WORK/nopath" "$WORK/fakepath"
printf '#!/bin/bash\necho 0\n' > "$WORK/fakepath/vercmp"
chmod +x "$WORK/fakepath/vercmp"
stage_here() { # <PATH>: the script on this host, with that PATH, for the options that reach it
	PATH="$1" /bin/bash "$HERE/scripts/assemble/stage-packages.sh" --admitted "$WORK/w/admitted" --manifest "$WORK/w/manifest.tsv" \
		--served "$WORK/none.tsv" --floor "$WORK/w/floor.txt" --out "$WORK/w/here"
}
check "no vercmp at all is a configuration error, not a refusal of a version" "2" "$(rc_of stage_here "$WORK/nopath")"
check "and the message names the tool that is missing" "1" "$(says 'vercmp, the tool of pacman that orders versions, is missing')"
check "a vercmp that does not answer -1 to 'vercmp 1 2' is a configuration error too" "2" "$(rc_of stage_here "$WORK/fakepath")"
check "and says what it answered wrong" "1" "$(says "does not answer -1 to 'vercmp 1 2'")"
check "neither wrote anything" "no" "$([ -e "$WORK/w/here" ] && echo yes || echo no)"

finish
