#!/usr/bin/env bash
#
# A publication that does not finish is reported and can be recovered from. This holds the three workflows to each other:
# publication-notice.yml hears the end of publish.yml, holds nothing but what it needs to open an issue, and its step is
# run here against a stand-in for gh; recover.yml writes in the same concurrency group as the publication, without the
# signing key, from the two artifacts publish.yml keeps long enough to be used.
#
# Requires: bash, python3 with PyYAML.
# shellcheck disable=SC2016 # the planted edits are text of python and of workflows, with ${{ }} meant literally
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"

# offences <workflows dir>: one line per broken tie
offences() {
	python3 -I - "$1" <<'PY'
import sys

import yaml


def load(name):
    with open(f"{sys.argv[1]}/{name}") as fh:
        spec = yaml.safe_load(fh)
    spec["on"] = spec.pop(True, spec.get("on"))
    return spec


publish, notice, recover = load("publish.yml"), load("publication-notice.yml"), load("recover.yml")
if notice["on"] != {"workflow_run": {"workflows": [publish["name"]], "types": ["completed"]}}:
    print("the notice does not hear the end of publish.yml, and only that")
if notice.get("permissions") != {} or list(notice["jobs"]) != ["notice"]:
    print("the notice holds more than its one job")
job = notice["jobs"]["notice"]
if job.get("permissions") != {"actions": "read", "issues": "write"}:
    print("the notice job does not hold exactly actions: read and issues: write")
if "environment" in job or any("uses" in s for s in job["steps"]) or "secrets." in str(job):
    print("the notice checks something out, uses an action or reads a secret")
if recover["on"] != {"workflow_dispatch": {"inputs": recover["on"]["workflow_dispatch"]["inputs"]}} \
        or recover["on"]["workflow_dispatch"]["inputs"]["run_id"].get("required") is not True:
    print("the recovery is not started by hand alone, with a run id")
if recover.get("concurrency") != publish.get("concurrency") or recover["concurrency"].get("cancel-in-progress") is not False:
    print("the recovery and the publication can write at once")
job = recover["jobs"]["recover"]
if job.get("environment") != "publish":
    print("the recovery does not run in the environment publish")
if "GPG_PRIVATE_KEY" in str(recover):
    print("the recovery reads the signing key")
kept = {}
for j in publish["jobs"].values():
    for step in j.get("steps", []):
        if str(step.get("uses", "")).startswith("actions/upload-artifact@"):
            kept[step["with"]["name"]] = step["with"].get("retention-days")
fetched = {}
for step in job["steps"]:
    if str(step.get("uses", "")).startswith("actions/download-artifact@"):
        w = step["with"]
        fetched[w["name"]] = (w.get("run-id"), w.get("github-token"))
want = ("${{ inputs.run_id }}", "${{ github.token }}")
if fetched != {"served": want, "signed-tree": want}:
    print("the recovery does not read exactly served and signed-tree of the run it is given")
for name in ("served", "signed-tree"):
    if kept.get(name) != 14:
        print(f"publish.yml does not keep the artifact {name} for 14 days")
PY
}
check "the three workflows hold to each other" "" "$(offences "$HERE/.github/workflows")"

# planted <name> <file> <python that edits the text s>: the offences of a copy with that edit
planted() {
	local d="$WORK/$1"
	mkdir -p "$d"
	cp "$HERE"/.github/workflows/{publish.yml,publication-notice.yml,recover.yml} "$d/"
	python3 -I -c 'import sys
p = sys.argv[1]; s = open(p).read(); n = eval(sys.argv[2]); assert n != s, "the edit changed nothing"; open(p, "w").write(n)' "$d/$2" "$3"
	offences "$d"
}
check "a publish workflow under another name is not heard" "the notice does not hear the end of publish.yml, and only that" \
	"$(planted renamed publish.yml 's.replace("name: Publish pacman repository", "name: Publish", 1)')"
check "a notice that also holds contents: write" "the notice job does not hold exactly actions: read and issues: write" \
	"$(planted wider publication-notice.yml 's.replace("      issues: write", "      issues: write\n      contents: write", 1)')"
check "a notice that checks the tree out" "the notice checks something out, uses an action or reads a secret" \
	"$(planted checkout publication-notice.yml 's.replace("    steps:\n", "    steps:\n      - uses: actions/checkout@v7\n", 1)')"
check "a recovery in a group of its own" "the recovery and the publication can write at once" \
	"$(planted group recover.yml 's.replace("group: publish-pacman", "group: recover", 1)')"
check "a recovery with no environment" "the recovery does not run in the environment publish" \
	"$(planted env recover.yml 's.replace("    environment: publish\n", "", 1)')"
check "a recovery that reads the artifacts of its own run" "the recovery does not read exactly served and signed-tree of the run it is given" \
	"$(planted own recover.yml 's.replace("          run-id: ${{ inputs.run_id }}\n", "", 1)')"
check "an artifact kept too short to recover from" "publish.yml does not keep the artifact signed-tree for 14 days" \
	"$(planted short publish.yml '__import__("re").sub(r"(name: signed-tree\n(?:.*\n){3} *retention-days: )14", r"\g<1>3", s)')"

# --- the step of the notice, run against a stand-in for gh --------------------------------------
python3 -I - "$HERE/.github/workflows/publication-notice.yml" > "$WORK/step.sh" <<'PY'
import sys

import yaml

with open(sys.argv[1]) as fh:
    print(yaml.safe_load(fh)["jobs"]["notice"]["steps"][0]["run"], end="")
PY
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
	"api "*) [ -z "${GH_API_FAIL:-}" ] || exit 1; printf '%s' "${GH_EXPIRY:-}" ;;
	"issue list") printf '%s\n' "${GH_OPEN:-}" ;;
	"issue create") printf '%s\n' "$@" >> "$GH_CREATED" ;;
	*) echo "unexpected gh $*" >&2; exit 64 ;;
esac
SH
chmod 755 "$WORK/bin/gh"
notice() { # <conclusion>: exit status; the issue it created, if any, is in $WORK/created
	local rc=0
	: > "$WORK/created"
	PATH="$WORK/bin:$PATH" GH_TOKEN=t REPO=Glyndor/pacman RUN_ID=4242 CONCLUSION="$1" GH_CREATED="$WORK/created" \
		bash "$WORK/step.sh" > "$WORK/last.out" 2>&1 || rc=$?
	echo "$rc"
}
created() { grep -c -F -- "$1" "$WORK/created" || true; }
export GH_EXPIRY="2026-12-10T06:00:00Z"
check "a publication that succeeded opens nothing" "0 0" "$(notice success) $(grep -c . "$WORK/created" || true)"
for how in failure cancelled timed_out; do
	check "a publication that ended as $how opens an issue" "0 1" "$(notice "$how") $(created "Publication run 4242 did not finish ($how)")"
done
check "the issue gives the run id to recover with" "1" "$(created 'run_id 4242')"
check "and the date its artifacts expire" "1" "$(created 'are kept until 2026-12-10T06:00:00Z')"
check "and its labels" "2" "$(grep -c -x -e 'type:bug' -e 'prio:P1' "$WORK/created" || true)"
check "a run that never kept both artifacts opens nothing" "0 0" "$(GH_EXPIRY="" notice failure) $(grep -c . "$WORK/created" || true)"
check "an open issue of the same title is not opened twice" "0 0" \
	"$(GH_OPEN="Publication run 4242 did not finish (failure)" notice failure) $(grep -c . "$WORK/created" || true)"
check "artifacts that cannot be read fail the notice" "1" "$(GH_API_FAIL=1 notice failure)"

finish
