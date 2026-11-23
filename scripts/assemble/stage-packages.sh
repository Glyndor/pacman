#!/usr/bin/env bash
#
# Put the admitted packages in the tree that is signed, after the order of versions is checked with the vercmp of pacman.
# Runs INSIDE the Arch image (run-in-arch.sh), as root, with no network and no secret.
#
#   stage-packages.sh --admitted <dir> --manifest <file> --served <file> --floor <file> --out <dir>
#
# <dir>/<repository>/<file> are the verified packages the manifest lists. <out>/arch/x86_64/ receives a copy of each and
# nothing else. A package older than the one served is refused, as is one below its line of <floor> (floor.txt, the highest
# version admitted before) and the same version with other bytes: vercmp is what pacman itself uses to decide.
# The database is not made here (repo-add is not run): it is written by the step that signs, from the manifest.
set -euo pipefail
export LC_ALL=C

admitted="" manifest="" served="" out="" floor=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::stage-packages.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--admitted) admitted="$2" ;;
		--manifest) manifest="$2" ;;
		--served) served="$2" ;;
		--out) out="$2" ;;
		--floor) floor="$2" ;;
		*) echo "::error::stage-packages.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$admitted" ] || [ -z "$manifest" ] || [ -z "$served" ] || [ -z "$out" ] || [ -z "$floor" ]; then
	echo "::error::usage: stage-packages.sh --admitted <dir> --manifest <file> --served <file> --floor <file> --out <dir>" >&2
	exit 2
fi
[ -f "$floor" ] || { echo "::error::the floor file $floor is not a file" >&2; exit 2; }
[ -s "$manifest" ] || { echo "::error::the manifest is empty; refusing to build an empty repository" >&2; exit 1; }
[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 2; }
tree="$out/arch/x86_64"
mkdir -p "$tree"

files=()
while IFS=$'\t' read -r repo package pkgver _arch file size sha _pq; do
	source_file="$admitted/$repo/$file"
	if [ -L "$source_file" ] || [ ! -f "$source_file" ]; then
		echo "::error::$source_file is not a regular file" >&2
		exit 1
	fi
	if [ "$(stat -c%s "$source_file")" != "$size" ] || [ "$(sha256sum "$source_file" | cut -d' ' -f1)" != "$sha" ]; then
		echo "::error::$file is not the file that was admitted" >&2
		exit 1
	fi
	while IFS=$'\t' read -r f_name f_ver extra; do
		case "$f_name" in '' | '#'*) continue ;; esac
		if [ -z "$f_ver" ] || [ -n "$extra" ]; then
			echo "::error::the floor file has a line that is not 'package<TAB>pkgver': $f_name" >&2
			exit 2
		fi
		[ "$f_name" = "$package" ] || continue
		if [ "$(vercmp "$pkgver" "$f_ver")" -lt 0 ]; then
			echo "::error::$package $pkgver is below the floor $f_ver, the highest version admitted before; a version never goes backwards" >&2
			exit 1
		fi
	done < "$floor"
	while IFS=$'\t' read -r s_name s_ver s_sha _s_file; do
		[ "$s_name" = "$package" ] || continue
		order="$(vercmp "$pkgver" "$s_ver")"
		if [ "$order" -lt 0 ]; then
			echo "::error::$package $pkgver is older than $s_ver, which is served; a version never goes backwards" >&2
			exit 1
		fi
		if [ "$order" -eq 0 ] && [ "$s_sha" != "$sha" ]; then
			echo "::error::$package $pkgver is served with other bytes; a new build needs a new version" >&2
			exit 1
		fi
	done < "$served"
	cp --no-dereference -- "$source_file" "$tree/$file"
	files+=("$file")
done < "$manifest"

# Nothing but the admitted packages leaves here. There is no database in the tree: the step that signs writes it from the
# manifest and the .PKGINFO the admission read (mkdb.py), and does not accept one from a step that ran over the packages.
cd "$tree"
expected="$(printf '%s\n' "${files[@]}" | sort)"
actual="$(find . -maxdepth 1 -mindepth 1 -printf '%f\n' | sort)"
if [ "$expected" != "$actual" ]; then
	echo "::error::the tree holds files that were not expected: $(diff <(echo "$expected") <(echo "$actual") | tr '\n' ' ')" >&2
	exit 1
fi
echo "staged ${#files[@]} package(s)"
