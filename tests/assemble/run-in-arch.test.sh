#!/usr/bin/env bash
#
# run-in-arch.sh: the way a script reaches the Arch image. What it must never do is hand that script a
# network, a capability, a secret or a writable copy of the repository, so the container engine here is a
# stand-in that writes down its arguments and the tests read them. Whether the image itself runs is the
# business of build-database.test.sh, which uses the real one.
#
# Requires: coreutils.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/assemble/run-in-arch.sh"
mkdir -p "$WORK/work"
cat > "$WORK/engine" <<'ENG'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ENGINE_LOG"
env | grep -c -e GLYNDOR -e SECRET > "$ENGINE_LOG.env" || true
ENG
chmod +x "$WORK/engine"
export ENGINE_LOG="$WORK/engine.log"
run() { CONTAINER_ENGINE="$WORK/engine" bash "$SCRIPT" "$@"; }
rc_of() { local rc=0; "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
has() { grep -c -x -F -- "$1" "$ENGINE_LOG" || true; }

check "a script of the repository runs" "0" "$(rc_of run scripts/admit/list-package.sh "$WORK/work" --out /work/x)"
check "with no network" "1" "$(has none)"
check "with every capability dropped" "1" "$(has ALL)"
check "and no new privileges" "1" "$(has no-new-privileges)"
check "the repository is mounted read-only" "1" "$(has "$HERE:/repo:ro")"
check "the work folder is the only writable mount" "1" "$(has "$WORK/work:/work:rw")"
check "the image is the one in arch-image.txt, by digest" "1" "$(grep -c -x -F -- "$(grep -v -e '^#' -e '^$' "$HERE/scripts/assemble/arch-image.txt")" "$ENGINE_LOG" || true)"
check "the script is run from the read-only copy" "1" "$(has /repo/scripts/admit/list-package.sh)"
check "the arguments follow the script" "1" "$(has /work/x)"
check "the environment of the caller does not reach the container (no --env, no --env-file)" "0" "$(grep -c -e '^--env' "$ENGINE_LOG" || true)"
check "a script outside scripts/ is refused" "2" "$(rc_of run /bin/sh "$WORK/work")"
check "a path that climbs is refused" "2" "$(rc_of run scripts/../tests/x.sh "$WORK/work")"
check "a script that is not a .sh is refused" "2" "$(rc_of run scripts/metadata/dbtool.py "$WORK/work")"
check "a script that is not there is refused" "2" "$(rc_of run scripts/assemble/none.sh "$WORK/work")"
check "a work folder that is not there is refused" "2" "$(rc_of run scripts/admit/list-package.sh "$WORK/none")"
check "no arguments at all" "2" "$(rc_of bash "$SCRIPT")"
mkdir -p "$WORK/nobin"
for tool in grep dirname timeout; do ln -s "$(command -v "$tool")" "$WORK/nobin/$tool"; done
noengine() { PATH="$WORK/nobin" /usr/bin/env -i PATH="$WORK/nobin" /bin/bash "$SCRIPT" scripts/admit/list-package.sh "$WORK/work"; }
check "no engine installed is refused" "2" "$(rc_of noengine)"
check "and says that neither docker nor podman is installed" "1" "$(grep -c 'neither docker nor podman' "$WORK/last.out" || true)"

finish
