#!/usr/bin/env bash
#
# Print the Arch Linux image the repository builds and checks in, by digest and with no tag:
# docker.io/library/archlinux@sha256:<64 hex>. It is read from the one `FROM` line of
# scripts/assemble/Dockerfile, the file Dependabot moves, so there is a single place to change.
#
# Anything else in that file is an error and prints nothing: a second `FROM`, a tag with no
# digest, another repository, or no line at all, so a script never runs in an image nobody pinned.
#
# Usage: arch-image.sh [<Dockerfile>]   (default: the one next to this script)
set -euo pipefail

file="${1:-$(dirname "${BASH_SOURCE[0]}")/Dockerfile}"
[ -f "$file" ] || { echo "::error::$file does not exist" >&2; exit 2; }
from="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$file")" || from=""
if [ "$(printf '%s\n' "$from" | grep -c .)" -ne 1 ]; then
	echo "::error::$file must hold exactly one FROM line and nothing else" >&2
	exit 2
fi
re='^FROM docker\.io/library/archlinux(:[A-Za-z0-9._-]+)?@sha256:([0-9a-f]{64})$'
if [[ ! "$from" =~ $re ]]; then
	echo "::error::the FROM line of $file is not the archlinux image of Docker Hub pinned by sha256" >&2
	exit 2
fi
printf 'docker.io/library/archlinux@sha256:%s\n' "${BASH_REMATCH[2]}"
