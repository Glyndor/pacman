#!/usr/bin/env bash
#
# Run a script of this repository inside the Arch image, with no network, no capability and the repository
# mounted read-only, so that what builds the database cannot reach a secret or the network.
#
#   run-in-arch.sh <script under scripts/> <work dir> <script arguments...>
#
# <work dir> is the only writable mount; every path the script is given is inside it (as /work/...) or in
# the repository (as /repo/...). The image is the digest in arch-image.txt, and the engine is docker or podman.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -lt 2 ]; then
	echo "::error::usage: run-in-arch.sh <script under scripts/> <work dir> <arguments...>" >&2
	exit 2
fi
script="$1"
work="$2"
shift 2
case "$script" in
	*..* | */./* | */ | *' '*) echo "::error::$script is not a plain path" >&2; exit 2 ;;
	scripts/*.sh) ;;
	*) echo "::error::$script is not a script under scripts/" >&2; exit 2 ;;
esac
[ -f "$HERE/$script" ] || { echo "::error::$script does not exist" >&2; exit 2; }
[ -d "$work" ] || { echo "::error::$work is not a folder" >&2; exit 2; }
image="$(grep -v -e '^#' -e '^$' "$HERE/scripts/assemble/arch-image.txt")"
[[ "$image" =~ ^docker\.io/library/archlinux@sha256:[0-9a-f]{64}$ ]] \
	|| { echo "::error::scripts/assemble/arch-image.txt does not hold one image by digest" >&2; exit 2; }
engine="${CONTAINER_ENGINE:-}"
if [ -z "$engine" ]; then
	for candidate in docker podman; do
		# One that is installed and does not answer (a docker with no daemon, a shim) is not an engine.
		if command -v "$candidate" > /dev/null && timeout 60 "$candidate" info > /dev/null 2>&1; then
			engine="$candidate"
			break
		fi
	done
fi
[ -n "$engine" ] || { echo "::error::neither docker nor podman is installed" >&2; exit 2; }
command -v "$engine" > /dev/null || { echo "::error::the container engine $engine is not installed" >&2; exit 2; }
exec timeout 900 "$engine" run --rm --network none --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
	--security-opt no-new-privileges --pids-limit 256 --memory 2g \
	--volume "$HERE:/repo:ro" --volume "$(cd "$work" && pwd):/work:rw" \
	"$image" bash "/repo/$script" "$@"
