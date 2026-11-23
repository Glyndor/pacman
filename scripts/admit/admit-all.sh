#!/usr/bin/env bash
#
# Admit the latest release of every product of the products file.
#
#   admit-all.sh --out <dir> --served <file> [--first-publication] [admit-product.sh options]
#
# <file> lists what the repository serves today, one package per line, name first and then a
# TAB and anything else. A product whose latest release carries no pacman package is skipped
# while none of its packages is served, and stops the run once one is: a repository that is
# rebuilt from the admitted set would otherwise drop it without a word. That is also why a
# product that has not published yet (helmly, epistle-panel) needs no change here the day it does.
# Without --first-publication an empty served list is refused, because an unreadable or deleted
# database reads the same as an empty one and would let every product through as new.
#
# <file> carries, per line, name, pkgver, SHA-256 and file of what is served: a package of the same name and
# pkgver with another hash is refused, and so is one of a version older than the served one.
#
# Writes <dir>/manifest.tsv, the packages admitted, one per line: repository, package, pkgver,
# arch, file, size, sha256, whether an ML-DSA-65 signature was checked.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="" served="" first=no
products="$HERE/scripts/admit/products.txt"
pass=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--first-publication) first=yes; shift; continue ;;
	esac
	[ "$#" -ge 2 ] || { echo "::error::admit-all.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--out) out="$2" ;;
		--served) served="$2" ;;
		--products) products="$2"; pass+=("$1" "$2") ;;
		--ed25519-keys | --mldsa-keys | --pq-required | --signers | --python) pass+=("$1" "$2") ;;
		*) echo "::error::admit-all.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$out" ] || [ -z "$served" ]; then
	echo "::error::usage: admit-all.sh --out <dir> --served <file> [--first-publication]" >&2
	exit 2
fi
[ -f "$served" ] || { echo "::error::$served is not a file: the list of what is served is required" >&2; exit 2; }
# The list is read once, strictly: every line is exactly name, pkgver, sha256 and file, the last line is ended, and
# an empty list is refused unless this is the first publication (an unreadable or deleted database reads the same
# as an empty one, and would let every product through as new).
allow=()
[ "$first" = no ] || allow=(--allow-empty)
python3 -I "$HERE/scripts/admit/served.py" --served "$served" --manifest /dev/null "${allow[@]}" > /dev/null || exit 1
mkdir -p "$out"
[ ! -e "$out/manifest.tsv" ] || { echo "::error::$out/manifest.tsv already exists" >&2; exit 2; }

# Repositories in the order of the file, each once.
repos=()
while IFS=$'\t' read -r repo _; do
	case "$repo" in '' | '#'*) continue ;; esac
	case " ${repos[*]:-} " in *" $repo "*) ;; *) repos+=("$repo") ;; esac
done < "$products"
[ "${#repos[@]}" -gt 0 ] || { echo "::error::$products declares no product" >&2; exit 2; }

# What the file declares, read once: a read that fails stops the run and is not an empty list.
declared="$(grep -v -e '^#' -e '^$' "$products")" || { echo "::error::cannot read the products of $products" >&2; exit 2; }
# A package that is served and that no line of the file declares any more has left on purpose: the file is
# the reviewed list of what the repository carries, so removing a line is how a package retires. Said aloud.
while IFS=$'\t' read -r served_name _rest; do
	[ -n "$served_name" ] || continue
	if ! printf '%s\n' "$declared" | cut -f2 | grep -qxF -- "$served_name"; then
		echo "::notice::$served_name is served and no longer declared in $products: it leaves the repository and is retired by the state"
	fi
done < "$served"
for repo in "${repos[@]}"; do
	rc=0
	bash "$HERE/scripts/admit/admit-product.sh" --repo "$repo" --out "$out" "${pass[@]}" || rc=$?
	case "$rc" in
		0) continue ;;
		10) ;;
		*) exit "$rc" ;;
	esac
	while IFS=$'\t' read -r owner package _; do
		[ "$owner" = "$repo" ] || continue
		if cut -f1 "$served" | grep -qxF -- "$package"; then
			echo "::error::$package is served and the latest release of Glyndor/$repo carries no package of it; refusing to drop it from the repository" >&2
			exit 1
		fi
	done <<< "$declared"
	echo "::notice::Glyndor/$repo has no pacman package yet and none is served: skipped"
done

: > "$out/manifest.tsv"
for repo in "${repos[@]}"; do
	[ ! -f "$out/$repo.manifest" ] || cat "$out/$repo.manifest" >> "$out/manifest.tsv"
done
[ -s "$out/manifest.tsv" ] || { echo "::error::no product carried a package; refusing to publish an empty repository" >&2; exit 1; }
# A published identity never changes bytes and a version never goes backwards: the candidate is compared with what is
# served, by the numbers of X.Y.Z[+rN]-1, and refused when it is older or has other bytes under the same version.
python3 -I "$HERE/scripts/admit/served.py" --served "$served" --manifest "$out/manifest.tsv" "${allow[@]}" > /dev/null || exit 1
# What the packages say (.PKGINFO), of every product in one file, for the signer to compare the database with.
python3 -I - "$out" "${repos[@]}" <<'PY'
import json, os, sys
out, repos = sys.argv[1], sys.argv[2:]
merged = {}
for repo in repos:
	path = os.path.join(out, repo + ".manifest.pkginfo.json")
	if os.path.exists(path):
		merged.update(json.load(open(path)))
with open(os.path.join(out, "pkginfo.json"), "x") as f:
	json.dump(merged, f, sort_keys=True)
PY
dups="$(cut -f2 "$out/manifest.tsv" | sort | uniq -d)"
[ -z "$dups" ] || { echo "::error::two products admit the same package: $dups" >&2; exit 1; }
echo "admitted $(wc -l < "$out/manifest.tsv") package(s)"
