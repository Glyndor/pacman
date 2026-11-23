#!/usr/bin/env bash
#
# Admit the pacman packages of the latest release of one product repository.
#
#   admit-product.sh --repo <name> --out <dir> [--products <file>] [--ed25519-keys <file>]
#                    [--mldsa-keys <file>] [--pq-required <file>] [--signers <file>] [--paths <file>] [--scriptlets <file>] [--python <exe>]
#
# The release is resolved once, to a tag, and everything after reads that tag, so a release
# published while this runs cannot hand the packages and their signatures two versions.
# Which files are fetched is decided by admit.py from the tag and from the products file, never
# by a pattern: a release is a listing somebody else controls. What lands in <out>/<repo>/ is
# verified by admit.py against the release key and described in <out>/<repo>.manifest, and each
# package must also carry a provenance attestation of its repository.
#
# Nothing reaches <out> until every gate has passed, the attestation included: the release is admitted in a folder of
# its own and moved into <out> at the very end, so a refusal leaves <out> as it was.
#
# Exit 0 admitted, 10 the release carries no pacman package of this product, anything else refused.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="" out=""
products="$HERE/scripts/admit/products.txt"
ed_keys="$HERE/keyring/glyndor-release-ed25519.b64"
pq_keys="$HERE/keyring/glyndor-release-mldsa65.b64"
pq_required="$HERE/keyring/pq-required-products"
signers="$HERE/scripts/admit/signer-workflows.txt"
paths="$HERE/scripts/admit/package-paths.txt"
scriptlets="$HERE/scripts/admit/package-scriptlets.txt"
python="python3"
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::admit-product.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--repo) repo="$2" ;;
		--out) out="$2" ;;
		--products) products="$2" ;;
		--ed25519-keys) ed_keys="$2" ;;
		--mldsa-keys) pq_keys="$2" ;;
		--pq-required) pq_required="$2" ;;
		--signers) signers="$2" ;;
		--paths) paths="$2" ;;
		--scriptlets) scriptlets="$2" ;;
		--python) python="$2" ;;
		*) echo "::error::admit-product.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$repo" ] || [ -z "$out" ]; then
	echo "::error::usage: admit-product.sh --repo <name> --out <dir>" >&2
	exit 2
fi
[[ "$repo" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "::error::'$repo' is not a repository name" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
final="$out/$repo"
if [ -e "$final" ] || [ -e "$final.manifest" ]; then
	echo "::error::$final already exists; a release is admitted into an empty place" >&2
	exit 2
fi
# Everything is made here and moved at the end.
stage="$work/stage"
mkdir -p "$stage"
dest="$stage/$repo"

tag="$(timeout 120 gh release view --repo "Glyndor/$repo" --json tagName --jq .tagName)" \
	|| { echo "::error::could not resolve the latest release of Glyndor/$repo" >&2; exit 1; }
if [ -z "$tag" ] || [ "$(printf '%s\n' "$tag" | wc -l)" -ne 1 ]; then
	echo "::error::the latest release of Glyndor/$repo has no usable tag" >&2
	exit 1
fi
timeout 120 gh release view "$tag" --repo "Glyndor/$repo" --json assets > "$work/assets.json" \
	|| { echo "::error::could not list the assets of Glyndor/$repo $tag" >&2; exit 1; }

admit() { "$python" -I "$HERE/scripts/admit/admit.py" "$@"; }
common=(--products "$products" --repo "$repo" --tag "$tag" --assets "$work/assets.json")

rc=0
admit plan "${common[@]}" > "$work/plan.tsv" || rc=$?
if [ "$rc" -eq 10 ]; then
	echo "Glyndor/$repo $tag carries no pacman package"
	exit 10
fi
[ "$rc" -eq 0 ] || exit "$rc"

mkdir -p "$dest"
while IFS=$'\t' read -r _kind _package name _size; do
	# The name was checked by admit.py to be what the tag and the products file derive, and that
	# is made of characters a glob does not treat as one. gh still reads it as a glob, so a
	# name that is not the plain text it would match is the one thing refused again here.
	[[ "$name" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]] || { echo "::error::refusing to download '$name'" >&2; exit 1; }
	[[ "$_size" =~ ^[0-9]+$ ]] || { echo "::error::the plan gives '$_size' as the size of $name" >&2; exit 1; }
	# The size the release announced, and a little more, is the most this download may write: a file that is bigger than it
	# said is cut off by the limit and refused, it is not downloaded whole first.
	( ulimit -f "$((_size / 1024 + 16))" && timeout 600 gh release download "$tag" --repo "Glyndor/$repo" --pattern "$name" --dir "$dest" --clobber ) \
		|| { echo "::error::could not download $name from Glyndor/$repo $tag (or it is larger than the release says)" >&2; exit 1; }
done < "$work/plan.tsv"

admit check "${common[@]}" --dir "$dest" --ed25519-keys "$ed_keys" --mldsa-keys "$pq_keys" \
	--pq-required "$pq_required" --paths "$paths" --scriptlets "$scriptlets" --python "$python" --out "$stage/$repo.manifest"

# Provenance: the package was built by a workflow of the repository it came from, FOR THIS TAG. The
# signature says the release key signed it; this says where and from which commit it was built. An
# attestation of another release of the same product is valid for gh and is not this one, so the tag
# and the commit it points to are part of the question, and a self-hosted runner is not accepted.
workflow="$(awk -F'\t' -v r="$repo" '$1 == r { print $2 }' "$signers")" \
	|| { echo "::error::cannot read $signers" >&2; exit 2; }
[[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] \
	|| { echo "::error::$signers names no signing workflow for $repo" >&2; exit 2; }
commit="$(timeout 120 gh api "repos/Glyndor/$repo/commits/refs/tags/$tag" --jq .sha)" \
	|| { echo "::error::could not resolve the commit of $tag in Glyndor/$repo" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::the commit of $tag in Glyndor/$repo is not a SHA-1: '$commit'" >&2; exit 1; }
while IFS=$'\t' read -r _repo _package _version _arch file _rest; do
	timeout 300 gh attestation verify "$dest/$file" --repo "Glyndor/$repo" --source-ref "refs/tags/$tag" \
		--signer-workflow "Glyndor/$repo/.github/workflows/$workflow" --source-digest "$commit" --deny-self-hosted-runners > /dev/null \
		|| { echo "::error::$file has no provenance attestation of Glyndor/$repo for $tag at $commit" >&2; exit 1; }
done < "$stage/$repo.manifest"
printf '%s\t%s\n' "$repo" "$tag" > "$stage/$repo.tag"
# Every gate has passed: only now does anything reach <out>.
mkdir -p "$out"
mv -- "$dest" "$final"
for suffix in .manifest .manifest.pkginfo.json .tag; do
	mv -- "$stage/$repo$suffix" "$out/$repo$suffix"
done
echo "admitted Glyndor/$repo $tag"
