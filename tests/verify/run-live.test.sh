#!/usr/bin/env bash
#
# run-live.sh: how a script reaches an Arch container with the network, and how the host that the first run made is kept
# for the second. The engine here writes down its calls, so the tests say which image was used (the one pinned by digest,
# or the Arch of today), that the repository is mounted read-only, that the host is committed after `install` and used by
# `upgrade`, and that what is not understood stops before any container is started.
#
# Requires: coreutils.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/verify/run-live.sh"
cat > "$WORK/engine" <<'ENG'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ENGINE_LOG"
ENG
chmod +x "$WORK/engine"
export ENGINE_LOG="$WORK/engine.log" CONTAINER_ENGINE="$WORK/engine"
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
calls() { grep -c -- "$1" "$ENGINE_LOG" || true; }
PIN="$(bash "$HERE/scripts/assemble/arch-image.sh")"

: > "$ENGINE_LOG"
check "install on the pinned image" "0" "$(rc_of bash "$SCRIPT" install --image pinned --state host1 --base https://pacman.example.org --package podup --expect 1.0.0-1)"
check "runs the container once, on the image pinned by digest" "1" "$(calls "^run --name host1-run .*$PIN bash /repo/scripts/verify/install-live.sh install")"
check "with the repository read-only" "1" "$(calls "$HERE:/repo:ro")"
check "and the options after the script" "1" "$(calls 'install-live.sh install --base https://pacman.example.org --package podup --expect 1.0.0-1')"
check "the host is kept as an image for the upgrade" "1" "$(calls '^commit host1-run localhost/host1$')"
check "and the container is removed (once before, in case an earlier run left it, once after)" "2" "$(calls '^rm -f host1-run$')"
: > "$ENGINE_LOG"
check "install on the Arch of today" "0" "$(rc_of bash "$SCRIPT" install --image current --state host2 --package podup --expect 1.0.0-1 --base https://pacman.example.org)"
check "uses docker.io/library/archlinux:latest" "1" "$(calls 'docker.io/library/archlinux:latest bash')"
: > "$ENGINE_LOG"
check "install on the loopback uses the host network" "0" "$(rc_of bash "$SCRIPT" install --image pinned --state host3 --network host --package podup --expect 1.0.0-1 --base http://127.0.0.1:1)"
check "and says so to the engine" "1" "$(calls '^run --name host3-run --network host ')"
: > "$ENGINE_LOG"
check "the upgrade runs on the host that was kept" "0" "$(rc_of bash "$SCRIPT" upgrade --state host3 --network host --package podup --expect 1.1.0-1)"
check "from the image the install committed, removed afterwards" "1" "$(calls '^run --rm --network host --volume .* localhost/host3 bash /repo/scripts/verify/install-live.sh upgrade --package podup --expect 1.1.0-1$')"
: > "$ENGINE_LOG"
check "an image that is neither" "2" "$(rc_of bash "$SCRIPT" install --image latest --state h --package podup --expect 1.0.0-1 --base https://x.example.org)"
check "a state name with a slash" "2" "$(rc_of bash "$SCRIPT" install --image pinned --state ../x --package podup --expect 1.0.0-1)"
check "a network that is not host" "2" "$(rc_of bash "$SCRIPT" install --image pinned --state h --network bridge --package podup --expect 1.0.0-1)"
check "no mode" "2" "$(rc_of bash "$SCRIPT" --image pinned)"
check "an option with no value" "2" "$(rc_of bash "$SCRIPT" install --image)"
check "no engine answers" "2" "$(CONTAINER_ENGINE="" PATH="$WORK/none" rc_of /bin/bash "$SCRIPT" install --image pinned --state h --package podup --expect 1.0.0-1)"
check "and none of these started a container" "0" "$(calls '^run ')"

finish
