#!/usr/bin/env bash
#
# Write the landing page of the repository from the database that was built, so that what it says is what is served.
#
#   build-index-page.sh <database.tar.zst> <out file>
#
# It lists each package with the command to install it, and tells a reader to compare the fingerprint of the key
# with the README of the repository, which a page served from the repository cannot vouch for.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -ne 2 ]; then
	echo "::error::usage: build-index-page.sh <database.tar.zst> <out file>" >&2
	exit 2
fi
db="$1"
out="$2"
[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 1; }
entries="$(python3 -I "$HERE/scripts/metadata/dbtool.py" entries "$db")" || { echo "::error::cannot read $db" >&2; exit 1; }
{
	cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Glyndor pacman repository</title>
</head>
<body>
<h1>Glyndor pacman repository</h1>
<p>Packages for Arch Linux (x86_64), signed with the key whose fingerprint is in the
<a href="https://github.com/Glyndor/pacman#readme">README</a>. Compare it there before you trust this page.</p>
<p>The install command upgrades the system: <code>curl -fsSL https://pacman.glyndor.net/install/PACKAGE | sudo sh</code></p>
<ul>
HTML
	while IFS=$'\t' read -r name version _file _size _sha _arch; do
		[ -n "$name" ] || continue
		# Package names and versions were checked by dbtool.py; the page does not rely on that alone.
		[[ "$name" =~ ^[a-z0-9@_+][a-z0-9@._+-]+$ ]] || { echo "::error::refusing a package name that is not safe to print: $name" >&2; exit 1; }
		[[ "$version" =~ ^[A-Za-z0-9._+:~-]+$ ]] || { echo "::error::refusing a version that is not safe to print: $version" >&2; exit 1; }
		printf '<li><code>%s</code> %s: <code>curl -fsSL https://pacman.glyndor.net/install/%s | sudo sh</code></li>\n' "$name" "$version" "$name"
	done <<< "$entries"
	cat <<'HTML'
</ul>
</body>
</html>
HTML
} > "$out"
echo "wrote $out"
