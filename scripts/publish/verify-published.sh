#!/usr/bin/env bash
#
# Read the repository back from the public address and say whether it is what was published.
#
#   verify-published.sh --url <base> --tree <dir> --public-key <file> [--now <time>] [--attempts <n>] [--delay <s>] [--deep]
#
# What is served has to match, byte for byte, the files of the tree that was uploaded: the database group with its
# signatures, the state, the key, the page and the installers. The served database is then read the way a client
# reads it: its signature against the key of the repository, the state against it (current, not from the future, about
# this database), and every package it lists must be served with the size it says (with --deep, read in full: its hash, and its signature verified against it). The
# edge may hold the previous copy for a while after the purge, so a mismatch is read again, a few times, and only then
# is it a failure. Packages are named for their version and read once.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
url="" tree="" pub="" attempts=6 delay=10 deep=no
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--deep) deep=yes; shift; continue ;;
	esac
	[ "$#" -ge 2 ] || { echo "::error::verify-published.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--url) url="$2" ;;
		--tree) tree="$2" ;;
		--public-key) pub="$2" ;;
		--now) now="$2" ;;
		--attempts) attempts="$2" ;;
		--delay) delay="$2" ;;
		*) echo "::error::verify-published.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$url" ] || [ -z "$tree" ] || [ -z "$pub" ]; then
	echo "::error::usage: verify-published.sh --url <base> --tree <dir> --public-key <file>" >&2
	exit 2
fi
[[ "$attempts" =~ ^[1-9][0-9]*$ && "$delay" =~ ^[0-9]+$ ]] || { echo "::error::attempts and delay are numbers" >&2; exit 2; }
# Compared whole, and never with a glob: https://x@evil.test and http://127.0.0.1:1@evil.test/ are not origins.
[[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ || "$url" =~ ^http://127\.0\.0\.1:[0-9]+/?$ ]] || { echo "::error::$url is not an https origin (or the loopback, for the tests)" >&2; exit 2; }
url="${url%/}"
dir="$tree/arch/x86_64"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
home="$work/gnupg"
mkdir -m 700 "$home"
gpg --homedir "$home" --batch --quiet --import "$pub" 2> /dev/null || { echo "::error::cannot import the public key" >&2; exit 2; }
gpg --homedir "$home" --batch --export > "$work/ring.gpg"

# The files compared byte for byte: everything in the tree that is not a package, with the path it is served under.
paths=()
for f in glyndor-pacman-key.asc index.html; do
	[ ! -f "$tree/$f" ] || paths+=("$f")
done
if [ -d "$tree/install" ]; then
	for f in "$tree"/install/*; do
		[ ! -f "$f" ] || paths+=("install/$(basename "$f")")
	done
fi
for f in glyndor.db glyndor.db.sig glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig; do
	[ -f "$dir/$f" ] || { echo "::error::the tree has no arch/x86_64/$f" >&2; exit 1; }
	paths+=("arch/x86_64/$f")
done

fetch() { # <path> <out>: the HTTP status
	curl --silent --show-error --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 180 \
		--max-filesize 419430400 --header 'Cache-Control: no-cache' --output "$2" --write-out '%{http_code}' "$url/$1" 2> /dev/null || printf 000
}
check_once() { # prints the first thing that is wrong, status 1 if there is one
	local p code
	rm -rf "$work/served"
	mkdir -p "$work/served/arch/x86_64" "$work/served/install"
	for p in "${paths[@]}"; do
		code="$(fetch "$p" "$work/served/$p")"
		if [ "$code" != 200 ]; then echo "$url/$p answers $code"; return 1; fi
		if ! cmp -s "$work/served/$p" "$tree/$p"; then echo "$url/$p is not the file that was uploaded"; return 1; fi
	done
	for p in glyndor.db.tar.zst glyndor.state; do
		if ! gpgv --keyring "$work/ring.gpg" "$work/served/arch/x86_64/$p.sig" "$work/served/arch/x86_64/$p" > /dev/null 2>&1; then
			echo "the signature of the served $p does not verify with the key of the repository"
			return 1
		fi
	done
	if ! python3 -I "$HERE/scripts/metadata/dbtool.py" state-check "$work/served/arch/x86_64/glyndor.state" \
		--db "$work/served/arch/x86_64/glyndor.db.tar.zst" --now "$now" > "$work/state.out" 2>&1; then
		cat "$work/state.out"
		return 1
	fi
	local name version file size sha arch got entries
	entries="$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$work/served/arch/x86_64/glyndor.db.tar.zst")" \
		|| { echo "the served database cannot be read"; return 1; }
	while IFS=$'\t' read -r name version file size sha arch; do
		[ -n "$name" ] || continue
		if [ "$deep" = yes ]; then
			code="$(fetch "arch/x86_64/$file" "$work/package")"
			[ "$code" = 200 ] || { echo "$url/arch/x86_64/$file answers $code"; return 1; }
			got="$(sha256sum "$work/package" | cut -d' ' -f1)"
			[ "$got" = "$sha" ] || { echo "$url/arch/x86_64/$file is not the package the database describes"; return 1; }
			# The signature is read as well, and has to verify the package that was just read: a package served with a
			# signature of another one, or with none that reads, is not a repository a client can install from.
			code="$(fetch "arch/x86_64/$file.sig" "$work/package.sig")"
			[ "$code" = 200 ] || { echo "$url/arch/x86_64/$file.sig answers $code"; return 1; }
			if ! gpgv --keyring "$work/ring.gpg" "$work/package.sig" "$work/package" > /dev/null 2>&1; then
				echo "the signature of the served $file does not verify the served package with the key of the repository"
				return 1
			fi
		else
			got="$(curl --silent --head --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 60 --write-out '%{http_code} %header{content-length}' --output /dev/null "$url/arch/x86_64/$file" 2> /dev/null || echo '000 0')"
			[ "$got" = "200 $size" ] || { echo "$url/arch/x86_64/$file answers '$got', the database says $size bytes"; return 1; }
		fi
		if [ "$deep" != yes ]; then
			code="$(curl --silent --head --location --proto '=https,http' --max-redirs 3 --connect-timeout 20 --max-time 60 --write-out '%{http_code}' --output /dev/null "$url/arch/x86_64/$file.sig" 2> /dev/null || echo 000)"
			[ "$code" = 200 ] || { echo "$url/arch/x86_64/$file.sig answers $code"; return 1; }
		fi
		: "$version $arch"
	done <<< "$entries"
	return 0
}
for i in $(seq 1 "$attempts"); do
	if problem="$(check_once)"; then
		echo "the repository served at $url is the one that was published"
		exit 0
	fi
	echo "attempt $i of $attempts: $problem" >&2
	[ "$i" -eq "$attempts" ] || sleep "$delay"
done
echo "::error::the repository served at $url is not what was published: $problem" >&2
exit 1
