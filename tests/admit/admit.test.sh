#!/usr/bin/env bash
#
# admit.py plan: which files of a release the channel downloads, and what it refuses before it
# downloads anything. The release is a listing somebody else controls, so the set of names is derived
# from the tag and from the products file and compared for equality; an asset that looks like a package
# and is not in the set stops the release, it is not skipped.
#
# Requires: python3.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
ADMIT="$HERE/scripts/admit/admit.py"

printf 'podman\tpodman\tx86_64\tnetavark,docker\npodman\tpodman-docker\tany\tdocker\nacme\tacme\tx86_64\t-\nboth\tboth\tx86_64|any\t-\n' > "$WORK/products.txt"

# plan <repo> <tag> <asset name>... : the plan, or the refusal, for a release listing exactly these assets (size 10)
plan() {
	local repo="$1" tag="$2" first=1
	shift 2
	{
		printf '{"assets":['
		for name in "$@"; do
			[ "$first" -eq 1 ] || printf ','
			first=0
			printf '{"name":"%s","size":10}' "$name"
		done
		printf ']}'
	} > "$WORK/assets.json"
	python3 -I "$ADMIT" plan --products "${PRODUCTS:-$WORK/products.txt}" --repo "$repo" --tag "$tag" --assets "$WORK/assets.json" 2>&1
}
# code <command>: the exit status; 99 when the program crashed instead of refusing (a traceback is never a verdict)
code() {
	local rc=0
	"$@" > "$WORK/code.out" 2>&1 || rc=$?
	if grep -q 'Traceback' "$WORK/code.out"; then rc=99; fi
	echo "$rc"
}

A="acme-1.2.3-1-x86_64.pkg.tar.zst"
check "a release with its package and signature: both are planned, nothing else" \
	"package	acme	$A	10
sig	acme	$A.sig	10" "$(plan acme v1.2.3 "$A" "$A.sig" acme-linux-amd64 SHA256SUMS)"
check "the optional ML-DSA-65 signature is planned when it is there" \
	"mldsa	acme	$A.mldsa65.sig	10" "$(plan acme v1.2.3 "$A" "$A.sig" "$A.mldsa65.sig" | grep ^mldsa)"
check "assets that are not packages (binaries, .deb, sums) are ignored" \
	"2" "$(plan acme v1.2.3 "$A" "$A.sig" acme_1.2.3_amd64.deb acme_1.2.3_amd64.deb.sig components.txt | wc -l)"
check "a release with no pacman package at all is the 'nothing' status, not an error" \
	"10" "$(code plan acme v1.2.3 acme_1.2.3_amd64.deb)"
check "podman is admitted whole: both packages, each with its signature" \
	"4" "$(plan podman v6.2.0+r12 podman-6.2.0+r12-1-x86_64.pkg.tar.zst podman-6.2.0+r12-1-x86_64.pkg.tar.zst.sig \
		podman-docker-6.2.0+r12-1-any.pkg.tar.zst podman-docker-6.2.0+r12-1-any.pkg.tar.zst.sig | wc -l)"
check "a product with only one of its packages is refused" \
	"1" "$(code plan podman v6.2.0+r12 podman-6.2.0+r12-1-x86_64.pkg.tar.zst podman-6.2.0+r12-1-x86_64.pkg.tar.zst.sig)"
check "an x86_64|any product admits the one that is there" \
	"2" "$(plan both v1.0.0 both-1.0.0-1-any.pkg.tar.zst both-1.0.0-1-any.pkg.tar.zst.sig | wc -l)"
check "an x86_64|any product with both is refused" \
	"1" "$(code plan both v1.0.0 both-1.0.0-1-any.pkg.tar.zst both-1.0.0-1-any.pkg.tar.zst.sig both-1.0.0-1-x86_64.pkg.tar.zst both-1.0.0-1-x86_64.pkg.tar.zst.sig)"

echo "-- what is refused"
check "a package without its .sig" "1" "$(code plan acme v1.2.3 "$A")"
check "a .sig without its package" "1" "$(code plan acme v1.2.3 "$A.sig")"
check "a package of another version (an old one re-attached)" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" acme-1.2.2-1-x86_64.pkg.tar.zst)"
check "a package of another revision" "1" "$(code plan acme v1.2.3 acme-1.2.3-2-x86_64.pkg.tar.zst acme-1.2.3-2-x86_64.pkg.tar.zst.sig)"
check "a package of another architecture the product does not declare" "1" "$(code plan acme v1.2.3 acme-1.2.3-1-aarch64.pkg.tar.zst acme-1.2.3-1-aarch64.pkg.tar.zst.sig)"
check "an 'any' build of an x86_64 product" "1" "$(code plan acme v1.2.3 acme-1.2.3-1-any.pkg.tar.zst acme-1.2.3-1-any.pkg.tar.zst.sig)"
check "a package of another product name (a signed foreign package in the release)" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" evil-1.2.3-1-x86_64.pkg.tar.zst)"
check "another compression (.pkg.tar.xz) is a package-like asset that is not in the set" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" acme-1.2.3-1-x86_64.pkg.tar.xz)"
check "an upper-case spelling of the suffix is refused too" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" acme-1.2.3-1-x86_64.PKG.TAR.ZST)"
check "a second signature suffix (.sig.sig) is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "$A.sig.sig")"
check "a name with a path separator is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "../x.pkg.tar.zst")"
check "a name with a slash inside is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "a/b.pkg.tar.zst")"
check "a glob character in a package-like name is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "acme-*.pkg.tar.zst")"
check "a leading dash in a package-like name is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "--acme.pkg.tar.zst")"
check "a pre-release tag is refused" "1" "$(code plan acme v1.2.3-rc1 "$A" "$A.sig")"
check "a tag without the v is refused" "1" "$(code plan acme 1.2.3 "$A" "$A.sig")"
check "a tag with a path in it is refused" "1" "$(code plan acme 'v1.2.3/../x' "$A" "$A.sig")"
check "the same asset listed twice is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "$A")"
big=(); for i in $(seq 1 130); do big+=("note-$i.txt"); done
check "a release with 130 assets is read, only the exact set matters" "0" "$(code plan acme v1.2.3 "$A" "$A.sig" "${big[@]}")"
big=(); for i in $(seq 1 1001); do big+=("note-$i.txt"); done
check "a release with more assets than GitHub allows is refused" "1" "$(code plan acme v1.2.3 "$A" "$A.sig" "${big[@]}")"
check "a repository the products file does not declare is a configuration error" "2" "$(code plan nobody v1.2.3 "$A" "$A.sig")"

echo "-- sizes"
sized() { # <package size> <sig size>
	printf '{"assets":[{"name":"%s","size":%s},{"name":"%s.sig","size":%s}]}' "$A" "$1" "$A" "$2" > "$WORK/assets.json"
	python3 -I "$ADMIT" plan --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/assets.json" > /dev/null 2>&1 && echo ok || echo refused
}
check "a package of exactly 300 MiB is admitted" "ok" "$(sized 314572800 64)"
check "a package of one byte more is refused" "refused" "$(sized 314572801 64)"
check "an empty package is refused" "refused" "$(sized 0 64)"
check "a signature of 4096 bytes is admitted by size (verify-sig.py judges its content)" "ok" "$(sized 10 4096)"
check "a signature of 4097 bytes is refused" "refused" "$(sized 10 4097)"
printf '{"assets":[{"name":"%s","size":"10"},{"name":"%s.sig","size":64}]}' "$A" "$A" > "$WORK/assets.json"
check "a size that is not a number is refused" "1" "$(code python3 -I "$ADMIT" plan --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/assets.json")"
printf '{"assets":[{"name":"%s","size":true},{"name":"%s.sig","size":64}]}' "$A" "$A" > "$WORK/assets.json"
check "a size that is a boolean is refused" "1" "$(code python3 -I "$ADMIT" plan --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/assets.json")"
printf 'not json' > "$WORK/assets.json"
check "a listing that is not JSON is refused" "1" "$(code python3 -I "$ADMIT" plan --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/assets.json")"
printf '{"assets":[{"name":"%s","size":10,"digest":"md5:abc"}]}' "$A" > "$WORK/assets.json"
check "a digest that is not sha256 is refused" "1" "$(code python3 -I "$ADMIT" plan --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/assets.json")"

listed() { # <json>: the plan for acme with this listing, status and message
	printf '%s' "$1" > "$WORK/assets.json"
	python3 -I "$ADMIT" plan --products "$WORK/products.txt" --repo acme --tag v1.2.3 --assets "$WORK/assets.json" 2>&1 || true
}
# refusal <json> <words>: 1 when the plan says those words and did not crash saying them
refusal() {
	local out
	out="$(listed "$1")"
	if printf '%s' "$out" | grep -q Traceback; then echo 0; else printf '%s\n' "$out" | grep -c -F -- "$2" || true; fi
}
check "an asset with no name is refused, and says so" "1" "$(refusal '{"assets":[{"size":5}]}' 'no usable name or size')"
check "an asset with an empty name is refused" "1" "$(refusal '{"assets":[{"name":"","size":5}]}' 'no usable name or size')"
check "an asset whose name is not text is refused" "1" "$(refusal '{"assets":[{"name":7,"size":5}]}' 'no usable name or size')"
check "an asset with a negative size is refused" "1" "$(refusal '{"assets":[{"name":"a.txt","size":-1}]}' 'no usable name or size')"
check "an asset with a fractional size is refused" "1" "$(refusal '{"assets":[{"name":"a.txt","size":1.5}]}' 'no usable name or size')"
check "an asset that is not an object is refused, and says so" "1" "$(refusal '{"assets":["a.txt"]}' 'is not an object')"
check "a listing with no assets key says it is not a release listing" "1" "$(refusal '{"files":[]}' 'is not a release listing')"
check "a listing whose assets are not a list says so too" "1" "$(refusal '{"assets":{}}' 'is not a release listing')"
exactly1000=(); for i in $(seq 1 998); do exactly1000+=("note-$i.txt"); done
check "a release with exactly 1000 assets is read" "2" "$(plan acme v1.2.3 "$A" "$A.sig" "${exactly1000[@]}" | wc -l)"

msg() { # <what to say> <repo> <tag> <asset name>...: the plan's own words for this refusal
	local want="$1" out
	shift
	out="$(plan "$@")"
	if printf '%s' "$out" | grep -q Traceback; then echo 0; else printf '%s\n' "$out" | grep -c -F -- "$want" || true; fi
}
check "a tag that is not stable says what the channel serves" "1" "$(msg 'is not vX.Y.Z or vX.Y.Z+rN' acme v1.2.3-rc1 "$A" "$A.sig")"
check "an unsafe package-like name says so" "1" "$(msg 'unsafe name' acme v1.2.3 "$A" "$A.sig" 'a/b.pkg.tar.zst')"
check "a package of two architectures says that exactly one is admitted" "1" \
	"$(PRODUCTS="$WORK/products.txt" msg 'exactly one is admitted' both v1.0.0 both-1.0.0-1-any.pkg.tar.zst both-1.0.0-1-any.pkg.tar.zst.sig both-1.0.0-1-x86_64.pkg.tar.zst both-1.0.0-1-x86_64.pkg.tar.zst.sig)"
check "a package that is not in the derived set says so" "1" "$(msg 'not in the set derived from' acme v1.2.3 "$A" "$A.sig" evil-1.2.3-1-x86_64.pkg.tar.zst)"
check "a listing with a digest that is not sha256 says so" "1" "$(refusal '{"assets":[{"name":"a.txt","size":1,"digest":"md5:abc"}]}' 'is not a sha256')"
check "a listing with a digest in sha256 form is read" "0" "$(refusal '{"assets":[{"name":"a.txt","size":1,"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]}' 'is not a sha256')"

echo "-- the products file"
bad() { printf '%b' "$1" > "$WORK/bad.txt"; PRODUCTS="$WORK/bad.txt" code plan acme v1.2.3 "$A" "$A.sig"; }
check "three fields instead of four" "2" "$(bad 'acme\tacme\tx86_64\n')"
check "an architecture the channel has no port for (aarch64)" "2" "$(bad 'acme\tacme\taarch64\t-\n')"
check "the reserved keyring package name" "2" "$(bad 'acme\tglyndor-keyring\tany\t-\n')"
check "a package declared twice" "2" "$(bad 'acme\tacme\tx86_64\t-\nacme\tacme\tx86_64\t-\n')"
check "a space in place of a tab" "2" "$(bad 'acme acme x86_64 -\n')"
check "a relation that is not a package name" "2" "$(bad 'acme\tacme\tx86_64\tA B\n')"
check "a byte above 0x7f" "2" "$(bad 'acme\tacm\xc3\xa9\tx86_64\t-\n')"
check "and says so" "1" "$(printf 'acme\tacm\xc3\xa9\tx86_64\t-\n' > "$WORK/bad.txt"; PRODUCTS="$WORK/bad.txt" plan acme v1.2.3 "$A" "$A.sig" | grep -c 'neither printable ASCII')"
check "a products file that is not there says that it cannot read it" "1" "$(PRODUCTS="$WORK/none-at-all.txt" plan acme v1.2.3 "$A" "$A.sig" | grep -c 'cannot read the products file')"
check "a reserved package name with a valid repository" "2" "$(bad 'acme\tglyndor-keyring\tany\t-\n')"
check "an upper-case repository name" "2" "$(bad 'Acme\tacme\tx86_64\t-\n')"
check "an upper-case package name" "2" "$(bad 'acme\tAcme\tx86_64\t-\n')"
check "a products file that is not there" "2" "$(PRODUCTS="$WORK/none-at-all.txt" code plan acme v1.2.3 "$A" "$A.sig")"
check "a repository with no line" "2" "$(bad 'other\tother\tx86_64\t-\n')"
declared="$(grep -v -e '^#' -e '^$' "$HERE/scripts/admit/products.txt" | cut -f1 | sort -u)"
bad=0
while read -r repo; do
	rc="$(PRODUCTS="$HERE/scripts/admit/products.txt" code plan "$repo" v1.0.0 nothing.txt)"
	# Nothing to admit is the answer for a release that has no package; anything else is a broken file.
	[ "$rc" = 10 ] || bad=$((bad + 1))
done <<< "$declared"
check "the products file of this repository is well formed for every repository it names" "0" "$bad"

echo "-- the page that tells a product what to attach says what this script enforces"
DOC="$HERE/docs/product-contract.md"
consts="$(python3 -I - "$ADMIT" "$HERE/scripts/admit/package-reader.py" <<'PY'
import importlib.util, sys
def load(path, name):
	spec = importlib.util.spec_from_file_location(name, path)
	module = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(module)
	return module
m = load(sys.argv[1], "admit")
r = load(sys.argv[2], "reader")
print(m.MAX_PACKAGE_BYTES // 2**20, m.MAX_SIG_BYTES, m.MAX_ASSETS, r.MAX_UNPACKED_BYTES // 2**30, r.MAX_ENTRIES, r.MAX_PKGINFO_BYTES // 1024, m.PACKAGER, m.TAG_RE.pattern.replace("([", "[").replace("]+)", "]+").replace("(?:", "(").replace("?:", ""))
PY
)"
read -r pkg_mib sig_bytes assets unpacked_gib entries pkginfo_kib packager _ <<< "$consts"
packager="Glyndor <noreply@glyndor.net>"
for fact in "at most $pkg_mib MiB" "at most $sig_bytes bytes" "at most $assets assets" "at most $unpacked_gib GiB" "$entries entries" "at most $pkginfo_kib KiB" "$packager"; do
	check "the page says: $fact" "1" "$(grep -c -F -- "$fact" "$DOC" || true)"
done
check "the page gives the tag pattern the script uses" "1" "$(grep -c -F -- '^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$' "$DOC" || true)"
check "the page names the one reserved package" "1" "$(grep -c -F -- 'glyndor-keyring' "$DOC" || true)"

echo "-- every repository of the products file names its signing workflow"
missing=0
while read -r repo; do
	grep -q "^$repo	" "$HERE/scripts/admit/signer-workflows.txt" || missing=$((missing + 1))
done <<< "$declared"
check "so no admission stops for want of one" "0" "$missing"

finish
