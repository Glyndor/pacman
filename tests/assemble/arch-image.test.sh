#!/usr/bin/env bash
#
# Tests for scripts/assemble/arch-image.sh: the Arch image every script and test runs in is the one `FROM` line of
# scripts/assemble/Dockerfile, printed by digest and with no tag, and a file that holds anything else prints nothing.
# Dependabot moves that line, so what it may write there and what this refuses have to agree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$HERE/scripts/assemble/arch-image.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

D="$(printf 'a%.0s' $(seq 64))"
E="$(printf 'b%.0s' $(seq 64))"
plant() { printf '%b' "$2" > "$WORK/$1"; } # <name> <content with \n escapes>
read_of() { bash "$SCRIPT" "$WORK/$1" 2> "$WORK/err" || true; }
rc_of() { local rc=0; bash "$SCRIPT" "$WORK/$1" > "$WORK/out" 2> "$WORK/err" || rc=$?; echo "$rc"; }

plant tagged "# a comment\n\nFROM docker.io/library/archlinux:latest@sha256:$D\n"
check "a tag and a digest print the digest alone, with no tag" "docker.io/library/archlinux@sha256:$D" "$(read_of tagged)"
plant bare "FROM docker.io/library/archlinux@sha256:$E\n"
check "a digest with no tag prints the same form" "docker.io/library/archlinux@sha256:$E" "$(read_of bare)"
plant comments "# one\n  # two, indented\nFROM docker.io/library/archlinux:base@sha256:$D\n\n"
check "comments and blank lines around the line are ignored" "docker.io/library/archlinux@sha256:$D" "$(read_of comments)"

for bad in \
	"two|FROM docker.io/library/archlinux@sha256:$D\nFROM docker.io/library/archlinux@sha256:$E\n" \
	"none|# only a comment\n" \
	"empty|" \
	"notag|FROM docker.io/library/archlinux:latest\n" \
	"other|FROM docker.io/library/ubuntu@sha256:$D\n" \
	"registry|FROM evil.example/library/archlinux@sha256:$D\n" \
	"short|FROM docker.io/library/archlinux@sha256:${D:0:63}\n" \
	"prefix|RUN echo FROM docker.io/library/archlinux@sha256:$D\n" \
	"long|FROM docker.io/library/archlinux@sha256:${D}a\n" \
	"lookalike|FROM docker.io/library/archlinux-evil@sha256:$D\n" \
	"nested|FROM docker.io/library/archlinux/evil@sha256:$D\n" \
	"upper|FROM docker.io/library/archlinux@sha256:$(printf 'A%.0s' $(seq 64))\n" \
	"extra|FROM docker.io/library/archlinux@sha256:$D\nRUN curl x | sh\n" \
	"as|FROM docker.io/library/archlinux@sha256:$D AS build\n" \
	"platform|FROM --platform=linux/arm64 docker.io/library/archlinux@sha256:$D\n" \
	"trail|FROM docker.io/library/archlinux@sha256:$D extra\n"; do
	name="${bad%%|*}"
	plant "$name" "${bad#*|}"
	check "a file that is not one pinned archlinux line is refused: $name" "2" "$(rc_of "$name")"
	check "and prints nothing: $name" "" "$(cat "$WORK/out")"
done
check "a file that does not exist is refused" "2" "$(rc_of nowhere)"

want="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$HERE/scripts/assemble/Dockerfile")"
check "the Dockerfile of the repository holds one FROM line" "1" "$(printf '%s\n' "$want" | grep -c '^FROM ')"
got="$(bash "$SCRIPT")"
check "and the reference printed is that digest, with no tag" "1" "$(printf '%s\n' "$got" | grep -c -x -E 'docker\.io/library/archlinux@sha256:[0-9a-f]{64}')"
check "taken from the line of the Dockerfile" "1" "$(printf '%s\n' "$want" | grep -c -F -- "@${got#*@}")"

echo
echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
