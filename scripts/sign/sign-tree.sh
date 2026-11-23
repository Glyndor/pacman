#!/usr/bin/env bash
#
# Sign the tree of the repository. The only step that holds the signing key, and it holds nothing else: it
# reads files, runs gpg, and writes signatures.
#
#   sign-tree.sh --tree <dir> --manifest <file> --pkginfo <file> --served <dir> --public-key <file> --fingerprint <hex> [--now <time>]
#
# The key arrives in GLYNDOR_PACMAN_GPG_PRIVATE_KEY, never as an argument. Before the key is imported, the
# tree is judged against the manifest of what was admitted: exactly the packages and nothing else, all regular files,
# each with the size and hash of the manifest. The database is then WRITTEN here, by mkdb.py, from that manifest and from the
# .PKGINFO the admission read (there is no files database): what the key signs is not the output of any tool that ran over the
# packages. A tree built by a step that ran other people's code is signed only if it holds what the admission admitted.
# The state (sequence, validity, retired packages) is written here, from the state served and the database, and signed
# with the rest. What reads those files runs without the key in its environment.
#
# Adds, beside each of the packages, glyndor.db.tar.zst and glyndor.state, a binary detached `.sig`; glyndor.db
# is a copy of the tar file and carries a copy of its signature.
# Every signature is read back with gpgv against the public key of the repository before the script ends.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tree="" manifest="" served="" pub="" fpr="" pkginfo=""
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::sign-tree.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--tree) tree="$2" ;;
		--manifest) manifest="$2" ;;
		--pkginfo) pkginfo="$2" ;;
		--served) served="$2" ;;
		--public-key) pub="$2" ;;
		--fingerprint) fpr="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::sign-tree.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$tree" ] || [ -z "$manifest" ] || [ -z "$pkginfo" ] || [ -z "$served" ] || [ -z "$pub" ] || [ -z "$fpr" ]; then
	echo "::error::usage: sign-tree.sh --tree <dir> --manifest <file> --pkginfo <file> --served <dir> --public-key <file> --fingerprint <hex>" >&2
	exit 2
fi
[[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || { echo "::error::the fingerprint is 40 upper-case hexadecimal digits" >&2; exit 2; }
if [ -z "${GLYNDOR_PACMAN_GPG_PRIVATE_KEY:-}" ]; then
	echo "::error::GLYNDOR_PACMAN_GPG_PRIVATE_KEY is not set; nothing is signed without it" >&2
	exit 1
fi
dir="$tree/arch/x86_64"
# What reads the files of the tree runs without the key in its environment: only the shell and gpg ever see it.
unkey=(env -u GLYNDOR_PACMAN_GPG_PRIVATE_KEY)
dbtool=("${unkey[@]}" python3 -I "$HERE/scripts/metadata/dbtool.py")

# 1. The tree is what was admitted, before the key is touched.
[ -d "$dir" ] || { echo "::error::$dir is not a folder" >&2; exit 1; }
expected="$(cut -f5 "$manifest" | sort)"
actual="$(find "$tree" -mindepth 1 -printf '%P\n' | grep -v -x -e arch -e arch/x86_64 | sort)"
if [ "$(printf '%s\n' "$expected" | sed 's|^|arch/x86_64/|')" != "$actual" ]; then
	echo "::error::the tree holds other files than the admitted packages (the database is written here, not received): $(diff <(printf '%s\n' "$expected" | sed 's|^|arch/x86_64/|') <(echo "$actual") | tr '\n' ' ')" >&2
	exit 1
fi
if [ -n "$(find "$tree" -mindepth 1 ! -type d ! -type f)" ] || [ -n "$(find "$tree" -type f -links +1)" ]; then
	echo "::error::the tree holds something that is not a regular file with one link" >&2
	exit 1
fi
# The database is written HERE, from the manifest of the admission and the .PKGINFO it read, never taken from the step that
# ran other people's code. The packages must be exactly the admitted ones (size and hash) for it to be written at all.
"${unkey[@]}" python3 -I "$HERE/scripts/metadata/mkdb.py" --manifest "$manifest" --pkginfo "$pkginfo" --packages "$dir" --out "$dir/glyndor.db.tar.zst"
cp -- "$dir/glyndor.db.tar.zst" "$dir/glyndor.db"

# 2. The key, in a folder of its own.
work="$(mktemp -d)"
home="$work/gnupg"
mkdir -m 700 "$home"
cleanup() {
	gpgconf --homedir "$home" --kill all > /dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT
printf '%s' "$GLYNDOR_PACMAN_GPG_PRIVATE_KEY" | gpg --homedir "$home" --batch --quiet --import 2> /dev/null \
	|| { echo "::error::the signing key cannot be imported" >&2; exit 1; }
secret="$(gpg --homedir "$home" --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10 }')"
if [ "$secret" != "$fpr" ]; then
	echo "::error::the secret key held is not the one named by the fingerprint, or there is more than one" >&2
	exit 1
fi
mkdir -m 700 "$work/verify"
gpg --homedir "$work/verify" --batch --quiet --import "$pub" 2> /dev/null || { echo "::error::cannot import the public key" >&2; exit 1; }
public="$(gpg --homedir "$work/verify" --batch --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10 }')"
[ "$public" = "$fpr" ] || { echo "::error::the public key of the repository is not the fingerprint named" >&2; exit 1; }
gpg --homedir "$work/verify" --batch --export > "$work/ring.gpg"

# The state: sequence, validity and what is retired, from the one served and the databases of this tree.
previous="-"
if [ ! -e "$served/no-state" ]; then
	previous="$served/state"
	[ -f "$previous" ] || { echo "::error::$served holds neither a state nor the mark of a first publication" >&2; exit 1; }
fi
"${dbtool[@]}" state-make --previous "$previous" --db "$dir/glyndor.db.tar.zst" \
	--now "$now" --served "$served/served.tsv" --out "$dir/glyndor.state"

# 3. Sign, then read every signature back.
signed=()
listing="$(cd "$dir" && ls -- *.pkg.tar.zst glyndor.db.tar.zst glyndor.state)" \
	|| { echo "::error::cannot list the files to sign" >&2; exit 1; }
while IFS= read -r file; do
	signed+=("$file")
done <<< "$listing"
for file in "${signed[@]}"; do
	gpg --homedir "$home" --batch --yes --quiet --pinentry-mode loopback --passphrase '' --local-user "$fpr" \
		--detach-sign --output "$dir/$file.sig" "$dir/$file"
done
cp -- "$dir/glyndor.db.tar.zst.sig" "$dir/glyndor.db.sig"
for file in "${signed[@]}" glyndor.db; do
	sig="$dir/$file.sig"
	[ "$file" != glyndor.db ] || sig="$dir/glyndor.db.sig"
	gpgv --keyring "$work/ring.gpg" "$sig" "$dir/$file" > /dev/null 2>&1 \
		|| { echo "::error::the signature of $file does not verify with the public key" >&2; exit 1; }
done
echo "signed ${#signed[@]} file(s) with $fpr"
