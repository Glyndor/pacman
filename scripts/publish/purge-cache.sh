#!/usr/bin/env bash
#
# Purge the edge cache of the files that change under a fixed name, by URL, never everything.
#
#   purge-cache.sh --url <base> --tree <dir> [--budget <seconds>] [--extra <file>]
#
# The packages are named for their version and cached for a year; what changes at every publication is the database
# group, the key, the page and the installers, and those are the URLs sent. The zone is shared with other sites, so a
# purge of everything is not an option. CF_TOKEN and CF_ZONE are in the environment; the token is handed to curl in a
# header file, not on the command line. Cloudflare takes at most 30 URLs a request, so the list goes in batches.
# <extra> names URLs (one per line, below <base>) to purge as well: what a publication removed.
set -euo pipefail
export LC_ALL=C

url="" tree="" budget=120 extra=""
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::purge-cache.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--url) url="$2" ;;
		--tree) tree="$2" ;;
		--budget) budget="$2" ;;
		--extra) extra="$2" ;;
		*) echo "::error::purge-cache.sh: unknown option $1" >&2; exit 2 ;;
	esac
	shift 2
done
if [ -z "$url" ] || [ -z "$tree" ]; then
	echo "::error::usage: purge-cache.sh --url <base> --tree <dir>" >&2
	exit 2
fi
[[ "$budget" =~ ^[0-9]+$ ]] || { echo "::error::the budget is a number of seconds" >&2; exit 2; }
[[ "$url" =~ ^https://[a-z0-9.-]+$ || "$url" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || { echo "::error::$url is not an https origin (or the loopback, for the tests)" >&2; exit 2; }
for v in CF_TOKEN CF_ZONE; do
	if [ -z "${!v:-}" ]; then
		echo "::error::$v is not configured" >&2
		exit 1
	fi
done
[[ "$CF_ZONE" =~ ^[0-9a-f]{32}$ ]] || { echo "::error::CF_ZONE is not a zone id" >&2; exit 1; }
api="${CF_API:-https://api.cloudflare.com/client/v4}"
# The token goes only to Cloudflare's API (or, for the tests, to the loopback).
# Compared whole: a glob such as http://127.0.0.1:* lets http://127.0.0.1:1@evil.test/ through, and the token goes there.
[[ "$api" = https://api.cloudflare.com/client/v4 || "$api" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || { echo "::error::$api is not the Cloudflare API" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The URLs: the fixed names of this tree, and what was removed.
urls=("$url/")
for f in glyndor-pacman-key.asc index.html; do
	[ ! -f "$tree/$f" ] || urls+=("$url/$f")
done
if [ -d "$tree/install" ]; then
	for f in "$tree"/install/*; do
		[ ! -f "$f" ] || urls+=("$url/install/$(basename "$f")")
	done
fi
for f in glyndor.db glyndor.db.sig glyndor.db.tar.zst glyndor.db.tar.zst.sig glyndor.state glyndor.state.sig; do
	[ -f "$tree/arch/x86_64/$f" ] || { echo "::error::the tree has no arch/x86_64/$f, which is purged by name" >&2; exit 1; }
	urls+=("$url/arch/x86_64/$f")
done
if [ -n "$extra" ]; then
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		[[ "$line" =~ ^[A-Za-z0-9._/@+-]+$ && "$line" != *..* ]] || { echo "::error::refusing to purge '$line'" >&2; exit 1; }
		urls+=("$url/$line")
	done < "$extra"
fi
[ "${#urls[@]}" -le 3000 ] || { echo "::error::too many URLs to purge" >&2; exit 1; }
for u in "${urls[@]}"; do
	[[ "$u" =~ ^https?://[A-Za-z0-9._/@+:-]+$ ]] || { echo "::error::refusing to purge '$u'" >&2; exit 1; }
done

printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN" > "$work/header"
chmod 600 "$work/header"
curl_post() { curl --silent --show-error --max-time 60 --connect-timeout 20 --config "$work/header" --header 'Content-Type: application/json' --request POST --data @"$work/body.json" --output "$work/answer.json" --write-out '%{http_code}' "$api/zones/$CF_ZONE/purge_cache"; }
deadline=$((SECONDS + budget))
sent=0
batch=0
while [ "$sent" -lt "${#urls[@]}" ]; do
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "::error::the purge ran out of its ${budget} seconds after $sent of ${#urls[@]} URL(s); the group from $url/${urls[$sent]#"$url/"} on is not purged" >&2
		exit 1
	fi
	chunk=("${urls[@]:sent:30}")
	python3 -I -c 'import json, sys; print(json.dumps({"files": sys.argv[1:]}))' "${chunk[@]}" > "$work/body.json"
	code="$(curl_post)" || code=000
	if [ "$code" != 200 ] || ! python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("success") is True else 1)' "$work/answer.json" 2> /dev/null; then
		echo "::error::the purge of ${#chunk[@]} URL(s) starting at ${chunk[0]} was refused (HTTP $code)" >&2
		exit 1
	fi
	sent=$((sent + ${#chunk[@]}))
	batch=$((batch + 1))
done
echo "purged $sent URL(s) in $batch request(s)"
