#!/usr/bin/env bash
#
# Read the published repository the way a client does and say whether it is sound, without needing the tree that was
# uploaded: the database and the state against the key of this repository (read-served.sh), the state current and about
# that database, every package listed served with the sha256 the database gives and a signature that verifies it, and the key served at the root
# the one in this repository.
#
#   check-served.sh --url <base> [--key <file>] [--out <dir>] [--floor <file>] [--now <time>]
#
# <dir> keeps what was read (served.tsv among it), for the checks that follow. This is what runs every six hours, and after
# each publication, from a clean runner.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
url="" key="$HERE/keyring/glyndor-pacman-key.asc" out="" now="" floor=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::check-served.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--url) url="$2" ;;
		--key) key="$2" ;;
		--floor) floor="$2" ;;
		--out) out="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::check-served.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
[ -n "$url" ] || { echo "::error::usage: check-served.sh --url <base> [--key <file>] [--out <dir>]" >&2; exit 2; }
url="${url%/}"
work="$(mktemp -d)"
# The agent of the temporary keyring is closed before its folder goes, and the folder of sockets GnuPG made for it goes
# with it: none is left running, and none is left behind.
trap 'gpgconf --homedir "$work/gnupg" --kill all > /dev/null 2>&1 || true; gpgconf --homedir "$work/gnupg" --remove-socketdir > /dev/null 2>&1 || true; rm -rf "$work"' EXIT
[ -n "$out" ] || out="$work/served"
at=()
[ -z "$now" ] || at=(--now "$now")
[ -z "$floor" ] || at+=(--floor "$floor")
bash "$HERE/scripts/metadata/read-served.sh" --url "$url" --out "$out" --key "$key" "${at[@]}"
[ -s "$out/served.tsv" ] || { echo "::error::the repository serves no package" >&2; exit 1; }
get_to() { curl --silent --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 300 --max-filesize 419430400 --output "$2" --write-out '%{http_code}' "$1" 2> /dev/null || echo 000; }
home="$work/gnupg"
mkdir -m 700 "$home"
gpg --homedir "$home" --batch --quiet --import "$key" 2> /dev/null || { echo "::error::cannot import the public key $key" >&2; exit 2; }
gpg --homedir "$home" --batch --export > "$work/ring.gpg"
entries="$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$out/glyndor.db.tar.zst")" || { echo "::error::the served database cannot be read" >&2; exit 1; }
while IFS=$'\t' read -r name _version file size sha _arch; do
	[ -n "$name" ] || continue
	got="$(get_to "$url/arch/x86_64/$file" "$work/package")"
	[ "$got" = 200 ] || { echo "::error::$url/arch/x86_64/$file answers $got" >&2; exit 1; }
	[ "$(sha256sum "$work/package" | cut -d' ' -f1)" = "$sha" ] \
		|| { echo "::error::$url/arch/x86_64/$file is not the package the database describes (its sha256 is not $sha)" >&2; exit 1; }
	got="$(get_to "$url/arch/x86_64/$file.sig" "$work/package.sig")"
	[ "$got" = 200 ] || { echo "::error::$url/arch/x86_64/$file.sig answers $got" >&2; exit 1; }
	gpgv --keyring "$work/ring.gpg" "$work/package.sig" "$work/package" > /dev/null 2>&1 \
		|| { echo "::error::the signature served for $file does not verify it with the key of this repository" >&2; exit 1; }
	: "$size"
done <<< "$entries"
code="$(curl --silent --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 60 --max-filesize 65536 --output "$work/key.asc" --write-out '%{http_code}' "$url/glyndor-pacman-key.asc" 2> /dev/null || echo 000)"
[ "$code" = 200 ] || { echo "::error::$url/glyndor-pacman-key.asc answers $code" >&2; exit 1; }
cmp -s "$work/key.asc" "$key" || { echo "::error::the key served is not the key of this repository" >&2; exit 1; }
echo "the repository served at $url holds together: $(wc -l < "$out/served.tsv") package(s), the state is current"
