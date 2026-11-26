#!/usr/bin/env bash
#
# check-recovery-run.sh accepts the id of a finished publication of this repository from main, and nothing else. gh is a
# stand-in that answers with the fields a case sets and records what it was asked.
#
# Requires: bash.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
SCRIPT="$HERE/scripts/publish/check-recovery-run.sh"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || { echo "gh: HTTP 404" >&2; exit 1; }
printf '%s\n' "$GH_ANSWER"
SH
chmod 755 "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" GH_LOG="$WORK/gh.log" REPO=Glyndor/pacman
answer() { printf '%s\t%s\t%s\t%s\t%s' "${1:-.github/workflows/publish.yml}" "${2:-main}" "${3:-workflow_dispatch}" "${4:-Glyndor/pacman}" "${5:-completed}"; }
run() { local rc=0; : > "$GH_LOG"; bash "$SCRIPT" "$@" > "$WORK/last.out" 2>&1 || rc=$?; echo "$rc"; }
says() { grep -c -F -- "$1" "$WORK/last.out" || true; }

export GH_ANSWER
GH_ANSWER="$(answer)"
check "a finished publication started by hand from main is accepted" "0" "$(run 123)"
check "and it is that run that was asked about" "1" "$(grep -c '^api repos/Glyndor/pacman/actions/runs/123 --jq ' "$GH_LOG")"
GH_ANSWER="$(answer '' '' schedule)"
check "and one started by the schedule" "0" "$(run 123)"
GH_ANSWER="$(answer .github/workflows/rehearsal.yml)"
check "a run of another workflow is refused" "1 1" "$(run 123) $(says 'is not a publication')"
GH_ANSWER="$(answer '' feature)"
check "a run of another branch is refused" "1 1" "$(run 123) $(says 'did not run on main')"
GH_ANSWER="$(answer '' '' '' someone/pacman)"
check "a run of another repository's main is refused" "1 1" "$(run 123) $(says 'did not run on main')"
GH_ANSWER="$(answer '' '' pull_request)"
check "a run started by a pull request is refused" "1 1" "$(run 123) $(says 'which a publication is not')"
GH_ANSWER="$(answer '' '' '' '' in_progress)"
check "a run that is not finished is refused" "1 1" "$(run 123) $(says 'still running is not recovered from')"
GH_ANSWER="$(answer)"
check "a run that cannot be read is refused" "1 1" "$(GH_FAIL=1 run 123) $(says 'cannot read run 123')"
# shellcheck disable=SC2016 # the command substitution is text, and has to reach the script as text
for bad in "" 0 12a "1/../2" "123 456" '$(id)'; do
	check "the id '$bad' is refused before gh is asked" "2 0" "$(run "$bad") $(grep -c . "$GH_LOG" || true)"
done
check "with no REPO nothing is asked" "2 0" "$(REPO="" run 123) $(grep -c . "$GH_LOG" || true)"

finish
