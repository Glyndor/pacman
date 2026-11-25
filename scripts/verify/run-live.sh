#!/usr/bin/env bash
#
# Run install-live.sh in a container of Arch Linux, with the network.
#
#   run-live.sh install --image <pinned|current> --state <name> [--network host] <install-live options>
#   run-live.sh upgrade --state <name> [--network host] <install-live options>
#
# `pinned` is the image of scripts/assemble/Dockerfile, by digest; `current` is the Arch of today (docker.io/library/archlinux:latest):
# the packages are built on the first and installed on what Arch is now, which is the case that breaks when a library
# moves. `install` leaves the host it made as an image called <state>, so that `upgrade` runs on the same host later.
# --network host reaches a server on the loopback (the rehearsal); the default is the network of the engine.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:-}"
shift || true
image="" state="" network=""
rest=()
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || { echo "::error::run-live.sh: $1 needs a value" >&2; exit 2; }
	case "$1" in
		--image) image="$2" ;;
		--state) state="$2" ;;
		--network) network="$2" ;;
		*) rest+=("$1" "$2") ;;
	esac
	shift 2
done
case "$mode" in install | upgrade) ;; *) echo "::error::usage: run-live.sh install|upgrade ..." >&2; exit 2 ;; esac
[[ "$state" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || { echo "::error::--state names the host that is kept between the two runs" >&2; exit 2; }
case "$network" in '' | host) ;; *) echo "::error::--network is host or nothing" >&2; exit 2 ;; esac
engine="${CONTAINER_ENGINE:-}"
if [ -z "$engine" ]; then
	for candidate in docker podman; do
		if command -v "$candidate" > /dev/null && timeout 60 "$candidate" info > /dev/null 2>&1; then
			engine="$candidate"
			break
		fi
	done
fi
[ -n "$engine" ] || { echo "::error::neither docker nor podman answers" >&2; exit 2; }
net=()
[ -z "$network" ] || net=(--network "$network")
if [ "$mode" = install ]; then
	case "$image" in
		pinned) image="$(bash "$HERE/scripts/assemble/arch-image.sh")" ;;
		current) image="docker.io/library/archlinux:latest" ;;
		*) echo "::error::--image is pinned or current" >&2; exit 2 ;;
	esac
	name="$state-run"
	"$engine" rm -f "$name" > /dev/null 2>&1 || true
	timeout 1800 "$engine" run --name "$name" "${net[@]}" --volume "$HERE:/repo:ro" "$image" bash /repo/scripts/verify/install-live.sh install "${rest[@]}"
	"$engine" commit "$name" "localhost/$state" > /dev/null
	"$engine" rm -f "$name" > /dev/null
else
	timeout 1800 "$engine" run --rm "${net[@]}" --volume "$HERE:/repo:ro" "localhost/$state" bash /repo/scripts/verify/install-live.sh upgrade "${rest[@]}"
fi
