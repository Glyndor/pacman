#!/usr/bin/env bash
#
# Generate one installer per package from scripts/pages/install-template.sh.
#
#   build-installers.sh <out-dir> <package> [<package> ...]
#
# The installer is the same script every time apart from the package name, and it does not change when a
# product cuts a release, so it is served from the repository and not attached to a release.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$HERE/scripts/pages/install-template.sh"
if [ "$#" -lt 2 ]; then
	echo "::error::usage: build-installers.sh <out-dir> <package> [<package> ...]" >&2
	exit 2
fi
out_dir="$1"
shift
[ -f "$TEMPLATE" ] || { echo "::error::missing template: $TEMPLATE" >&2; exit 1; }
# A template that lost its placeholder is still valid shell, and every package would get an installer that installs
# whatever name was left in it.
grep -q '@PRODUCT@' "$TEMPLATE" || { echo "::error::$TEMPLATE has no @PRODUCT@ placeholder" >&2; exit 1; }
mkdir -p "$out_dir"
for package in "$@"; do
	if ! [[ "$package" =~ ^[a-z0-9@_+][a-z0-9@._+-]+$ ]]; then
		echo "::error::refusing to generate an installer for '$package': it is not a pacman package name" >&2
		exit 1
	fi
	out="$out_dir/$package"
	[ ! -e "$out" ] || { echo "::error::$out already exists" >&2; exit 1; }
	sed "s/@PRODUCT@/$package/g" "$TEMPLATE" > "$out"
	chmod 0755 "$out"
	if grep -q '@PRODUCT@' "$out"; then
		echo "::error::$out still contains @PRODUCT@" >&2
		exit 1
	fi
	sh -n "$out" || { echo "::error::$out is not valid shell" >&2; exit 1; }
	[ "$(tail -n 1 "$out")" = '{ install_main; }' ] || { echo "::error::$out must end with { install_main; }" >&2; exit 1; }
	echo "generated $out"
done
