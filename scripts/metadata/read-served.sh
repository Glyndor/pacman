#!/usr/bin/env bash
#
# Read what the repository serves today, and trust none of it that is not signed.
#
#   read-served.sh --url <base> --out <dir> [--first-publication] [--key <file>] [--now <time>]
#
# <base> is https://pacman.glyndor.net (or, for the tests, http on the loopback). The database and the
# state are fetched with a size cap and a time cap, each with its signature,
# and each signature is checked against the public key of this repository with gpgv before anything
# else reads the file. The state must be current (not expired, not from the future) and about exactly
# this database. Writes <dir>/served.tsv (name, pkgver, sha256, file), <dir>/state and the databases,
# or <dir>/served.tsv empty and <dir>/no-state when the bucket is empty and the run says it is the
# first publication.
#
# Nothing but "every object answers 404" reads as an empty repository, and only with
# --first-publication: a database that goes missing, or answers an error, or has no state beside it,
# would otherwise look like a first publication to a run that then overwrites a good repository.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
url="" out="" first=no
key="$HERE/keyring/glyndor-pacman-key.asc"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--first-publication) first=yes; shift; continue ;;
	esac
	[ "$#" -ge 2 ] || { echo "::error::read-served.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--url) url="$2" ;;
		--out) out="$2" ;;
		--key) key="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::read-served.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$url" ] || [ -z "$out" ]; then
	echo "::error::usage: read-served.sh --url <base> --out <dir> [--first-publication]" >&2
	exit 2
fi
case "$url" in
	https://*/* | https://*[!/]) ;;
	http://127.0.0.1:* | http://localhost:*) ;;
	*) echo "::error::$url is not an https address (the loopback is the only plain http one)" >&2; exit 2 ;;
esac
url="${url%/}"
[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 2; }
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
base="$url/arch/x86_64"
names=(glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig)

# fetch <name>: the HTTP status, with the body in <dir>/<name> when it is 200
curl_get() { curl --silent --show-error --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 180 --max-filesize 134217728 "$@"; }
fetch() {
	local code
	code="$(curl_get --output "$out/$1" --write-out '%{http_code}' "$base/$1")" || code=000
	[ "$code" = 200 ] || rm -f "$out/$1"
	printf '%s' "$code"
}
declare -A status=()
for name in "${names[@]}"; do
	status[$name]="$(fetch "$name")"
done
absent=0
for name in "${names[@]}"; do
	[ "${status[$name]}" = 404 ] && absent=$((absent + 1))
done
if [ "$absent" -eq "${#names[@]}" ]; then
	if [ "$first" = yes ]; then
		: > "$out/served.tsv"
		: > "$out/no-state"
		echo "nothing is served; this is the first publication"
		exit 0
	fi
	echo "::error::the repository answers 404 everywhere and this is not the first publication; refusing to publish from nothing" >&2
	exit 1
fi
for name in "${names[@]}"; do
	if [ "${status[$name]}" != 200 ]; then
		echo "::error::$base/$name answered ${status[$name]}; the served repository is incomplete or unreadable, and is not replaced from a guess" >&2
		exit 1
	fi
done

# The key ring holds this repository's public key and nothing else.
home="$work/gnupg"
mkdir -m 700 "$home"
gpg --homedir "$home" --batch --quiet --import "$key" 2> /dev/null \
	|| { echo "::error::cannot import the public key $key" >&2; exit 2; }
gpg --homedir "$home" --batch --export > "$work/ring.gpg"
for name in glyndor.db.tar.zst glyndor.state; do
	gpgv --keyring "$work/ring.gpg" "$out/$name.sig" "$out/$name" > /dev/null 2>&1 \
		|| { echo "::error::the signature of the served $name does not verify with the key of this repository" >&2; exit 1; }
done
python3 -I "$HERE/scripts/metadata/dbtool.py" state-check "$out/glyndor.state" --db "$out/glyndor.db.tar.zst" --now "$now"
python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$out/glyndor.db.tar.zst" > "$work/entries.tsv"
awk -F'\t' '{ print $1 "\t" $2 "\t" $5 "\t" $3 }' "$work/entries.tsv" > "$out/served.tsv"
mv "$out/glyndor.state" "$out/state"
mv "$out/glyndor.state.sig" "$out/state.sig"
echo "served: $(wc -l < "$out/served.tsv") package(s), state $(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$out/state" sequence)"
