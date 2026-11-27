#!/usr/bin/env bash
#
# Read what the repository serves today, and trust none of it that is not signed.
#
#   read-served.sh --url <base> --out <dir> [--first-publication] [--expired-state "<sequence> <sha256>"] [--key <file>]
#                  [--floor <file>] [--now <time>]
#
# <base> is https://pacman.glyndor.net (or, for the tests, http on the loopback). The database and the
# state are fetched with a size cap and a time cap, each with its signature,
# and each signature is checked against the public key of this repository with gpgv before anything
# else reads the file. The state must be current (not expired, not from the future) and about exactly
# this database. Writes <dir>/served.tsv (name, pkgver, sha256, file), <dir>/state and the databases,
# or <dir>/served.tsv empty and <dir>/no-state when the bucket is empty and the run says it is the
# first publication.
#
# The served state is also compared with the one recorded in the repository (--floor, state-floor.txt): an earlier one,
# however well signed, is refused, and so is a repository that answers nothing once a state is recorded.
#
# An expired state is refused. --expired-state names one state, by its sequence and the sha256 of its database: that
# state, and no other, is read although it expired, so that somebody who established which one it should be can publish
# over it, or recover to it. Naming a range would let any state signed since the record stand in for the newest. Given,
# the served state has to be that one whether it expired or not. Everything else about it is checked the same, and what
# clients are served is never judged with it.
#
# Nothing but "every object answers 404" reads as an empty repository, and only with
# --first-publication: a database that goes missing, or answers an error, or has no state beside it,
# would otherwise look like a first publication to a run that then overwrites a good repository.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
url="" out="" first=no expected=""
floor="$HERE/scripts/metadata/state-floor.txt"
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
		--floor) floor="$2" ;;
		--expired-state) expected="$2" ;;
		--now) now="$2" ;;
		*) echo "::error::read-served.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$url" ] || [ -z "$out" ]; then
	echo "::error::usage: read-served.sh --url <base> --out <dir> [--first-publication] [--expired-state <state>]" >&2
	exit 2
fi
if [ -n "$expected" ] && ! [[ "$expected" =~ ^[1-9][0-9]{0,11}\ [0-9a-f]{64}$ ]]; then
	echo "::error::--expired-state takes '<sequence> <sha256 of the database>'" >&2
	exit 2
fi
# Compared whole, never with a glob: https://x@evil.test and http://127.0.0.1:1@evil.test/ are not origins.
[[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ || "$url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/?$ ]] \
	|| { echo "::error::$url is not an https origin (the loopback is the only plain http one)" >&2; exit 2; }
url="${url%/}"
[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 2; }
mkdir -p "$out"
work="$(mktemp -d)"
# The agent of the temporary keyring is closed before its folder goes, and the folder of sockets GnuPG made for it goes
# with it: none is left running, and none is left behind.
trap 'gpgconf --homedir "$work/gnupg" --kill all > /dev/null 2>&1 || true; gpgconf --homedir "$work/gnupg" --remove-socketdir > /dev/null 2>&1 || true; rm -rf "$work"' EXIT
base="$url/arch/x86_64"
names=(glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.db glyndor.db.sig glyndor.state glyndor.state.sig)

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
	# Once a state is recorded the repository has been served: answering nothing is it disappearing, not a first publication.
	recorded=0
	[ -f "$floor" ] && [ "$(grep -vE '^[[:space:]]*(#|$)' "$floor")" = none ] || recorded=1
	if [ "$first" = yes ] && [ "$recorded" = 1 ]; then
		echo "::error::the repository answers 404 everywhere and $floor does not say that nothing was published; refusing to publish from nothing" >&2
		exit 1
	fi
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
# pacman reads glyndor.db and glyndor.db.sig, not the .tar.zst: they have to be, byte for byte, the files that were verified.
cmp -s "$out/glyndor.db" "$out/glyndor.db.tar.zst" \
	|| { echo "::error::the served glyndor.db is not the file glyndor.db.tar.zst, whose signature verifies; the served repository is not sound" >&2; exit 1; }
cmp -s "$out/glyndor.db.sig" "$out/glyndor.db.tar.zst.sig" \
	|| { echo "::error::the served glyndor.db.sig is not the signature of glyndor.db.tar.zst that verifies; the served repository is not sound" >&2; exit 1; }
rm -f "$out/glyndor.db" "$out/glyndor.db.sig"
rc=0
bash "$HERE/scripts/metadata/check-state-floor.sh" "$out/glyndor.state" "$out/glyndor.db.tar.zst" "$floor" || rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || exit 1
replace=()
sequence="$(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$out/glyndor.state" sequence)"
digest="$(sha256sum "$out/glyndor.db.tar.zst" | cut -d' ' -f1)"
if [ -n "$expected" ]; then
	[ "$sequence $digest" = "$expected" ] \
		|| { echo "::error::the served state is '$sequence $digest' and the one asked for is '$expected'" >&2; exit 1; }
	replace=(--to-replace)
fi
if ! python3 -I "$HERE/scripts/metadata/dbtool.py" state-check "$out/glyndor.state" --db "$out/glyndor.db.tar.zst" --now "$now" "${replace[@]}"; then
	echo "the served state is '$sequence $digest'; docs/operations.md says when an expired one may be published over" >&2
	exit 1
fi
python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$out/glyndor.db.tar.zst" > "$work/entries.tsv"
awk -F'\t' '{ print $1 "\t" $2 "\t" $5 "\t" $3 }' "$work/entries.tsv" > "$out/served.tsv"
mv "$out/glyndor.state" "$out/state"
mv "$out/glyndor.state.sig" "$out/state.sig"
echo "served: $(wc -l < "$out/served.tsv") package(s), state $(python3 -I "$HERE/scripts/metadata/dbtool.py" state-get "$out/state" sequence)"
