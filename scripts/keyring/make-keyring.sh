#!/usr/bin/env bash
#
# Build the keyring package in the pinned image and add it to what was admitted, as one more row of the manifest.
#
#   make-keyring.sh --admitted <dir> --manifest <file> --pkginfo <file> [--epoch <seconds>]
#
# The version is `1.0.<epoch>` and the epoch is, unless one is given, the time of the last commit that changed what the
# package is made of (the key, this script and the one that builds it), so the version moves when those do and not at every
# run. That needs the history of the repository: a checkout without it stops here, it does not guess a time.
# The package goes to <dir>/glyndor/, its row to the manifest and what it says of itself to the file of .PKGINFO data.
# Its repository is `glyndor`, which no product can be called.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
admitted="" manifest="" epoch="" pkginfo=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::make-keyring.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--admitted) admitted="$2" ;;
		--manifest) manifest="$2" ;;
		--epoch) epoch="$2" ;;
		--pkginfo) pkginfo="$2" ;;
		*) echo "::error::make-keyring.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$admitted" ] || [ -z "$manifest" ] || [ -z "$pkginfo" ]; then
	echo "::error::usage: make-keyring.sh --admitted <dir> --manifest <file> --pkginfo <file> [--epoch <seconds>]" >&2
	exit 2
fi
[ -f "$manifest" ] || { echo "::error::$manifest is not a file" >&2; exit 2; }
[ -f "$pkginfo" ] || { echo "::error::$pkginfo is not a file" >&2; exit 2; }
[ ! -e "$admitted/glyndor" ] || { echo "::error::$admitted/glyndor already exists; the keyring is built into an empty place" >&2; exit 2; }
if [ -z "$epoch" ]; then
	epoch="$(git -C "$HERE" log -1 --format=%ct -- keyring/glyndor-pacman-key.asc scripts/keyring/build-keyring.sh scripts/keyring/make-keyring.sh)" \
		|| { echo "::error::cannot read the history of the inputs of the keyring package" >&2; exit 1; }
	[ -n "$epoch" ] || { echo "::error::the history has no commit of the inputs of the keyring package; check the repository out with its history" >&2; exit 1; }
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"
cp "$HERE/keyring/glyndor-pacman-key.asc" "$work/key.asc"
chmod 644 "$work/key.asc"
# The epoch is a number before it goes anywhere.
[[ "$epoch" =~ ^[1-9][0-9]{8,10}$ ]] || { echo "::error::the epoch is a number of seconds" >&2; exit 2; }
file="glyndor-keyring-1.0.$epoch-1-any.pkg.tar.zst"
bash "$HERE/scripts/assemble/run-in-arch.sh" scripts/keyring/build-keyring.sh "$work" --key /work/key.asc --epoch "$epoch" --out /work/out
# What the container left is untrusted. Only a file with the one name that is derived here is looked at: it is judged on the
# host (check-keyring.py: regular file, size and hash computed here, the two readers, the fixed fields and bytes), and the row
# and the .PKGINFO data are made from that judgement, never copied from the container.
verdict="$(python3 -I "$HERE/scripts/keyring/check-keyring.py" --package "$work/out/$file" --epoch "$epoch" --key "$HERE/keyring/glyndor-pacman-key.asc")" \
	|| { echo "::error::the keyring package that the container built was not accepted" >&2; exit 1; }
mkdir -p "$admitted/glyndor"
cp -- "$work/out/$file" "$admitted/glyndor/$file"
# The copy is what is hashed again: the file that is admitted is the one that was judged.
python3 -I - "$pkginfo" "$manifest" "$admitted/glyndor/$file" "$verdict" <<'PY'
import hashlib, json, os, sys
pkginfo_path, manifest_path, copy, verdict = sys.argv[1:5]
verdict = json.loads(verdict)
data = open(copy, "rb").read()
if hashlib.sha256(data).hexdigest() != verdict["sha256"] or len(data) != verdict["size"] or os.path.islink(copy):
	sys.exit("::error::the copy of the keyring package is not the file that was judged")
merged = json.load(open(pkginfo_path))
if verdict["file"] in merged:
	sys.exit("::error::the .PKGINFO data already holds an entry for the keyring package")
merged[verdict["file"]] = verdict["pkginfo"]
row = "\t".join(["glyndor", "glyndor-keyring", verdict["pkgver"], "any", verdict["file"], str(verdict["size"]), verdict["sha256"], "no"]) + "\n"
json.dump(merged, open(pkginfo_path, "w"), sort_keys=True)
with open(manifest_path, "a") as manifest:
	manifest.write(row)
PY
echo "added $file"
