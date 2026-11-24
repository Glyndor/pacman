#!/usr/bin/env bash
#
# The ruleset requires checks by name, and GitHub matches the name and nothing else: the
# check a pull request waits for can be produced by any run on the same commit, by any
# workflow and any event. A second workflow, or the same workflow on `push`, that emits
# the same name satisfies the requirement with a run that judged something else. The
# promotion of one branch to another points at a commit that already ran under the other
# event, which is how a green push run has stood in for a pull request.
#
# So this repository holds three things, and the planted workflows below break each:
#
#   * every workflow that is not a reusable runs on `pull_request` and on no other event,
#     so no check of this repository exists on a commit that no pull request judged;
#   * the names the workflows produce (the id of a job, or its `name`, and for a caller of
#     a local reusable the `id / inner name` GitHub shows) are all different, so no name
#     comes from two jobs or from two workflows;
#   * the names are exactly the list written here, which is the list the ruleset of
#     `main` is asked to require. A job added, renamed or removed changes this list in
#     the same pull request, where it is read.
#
# Requires: python3 with PyYAML.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

# The checks of a pull request, as the ruleset names them.
REQUIRED="commit identity
dco / Signed-off-by present on every commit
deprecations
empty-diff / empty diff
folder limit
gate
line-limit / line limit
secret scan
shell / shellcheck
shell / test
workflow-lint / workflow-lint"

# The workflows that are not checks of a pull request, each with the events it may run on, the names its jobs produce and
# whether those names MUST be produced (file, events, names, required). A name here is produced by that file and by nothing else.
# The analysis of CodeQL is required: the ruleset of main waits for `Analyze (actions)` and `Analyze (python)` (and for code
# scanning), so a pull request that removes the workflow or one of its jobs would leave a check that no run ever produces, or one
# that the ruleset stops waiting for. The publication and the verifications of the published repository are run by the schedule
# and by hand, from main, and none of them is a check of a pull request: they were `no` until their workflows were in the
# repository, and are `yes` now that they are. They run by hand only until the channel publishes for real: their cron is added in
# the pull request of the first publication, which adds `schedule` to the events of the row and a watcher for each cron. Any other workflow runs on pull_request alone.
NOT_PR="codeql.yml	pull_request push schedule	Analyze (actions)|Analyze (python)	yes
freshness.yml	pull_request push schedule	freshness-codeql / schedule freshness|freshness-itself / schedule freshness	yes
publish.yml	workflow_dispatch	admit|build|sign|publish|verify / served|verify / install	yes
verify-live.yml	workflow_dispatch	pinned / served|pinned / install|current / served|current / install|distro-newer	yes
rehearsal.yml	workflow_dispatch	rehearsal	yes"
NOT_PR_NAMES="$(printf '%s\n' "$NOT_PR" | cut -f3 | tr '|' '\n')"
NOT_PR_REQUIRED="$(printf '%s\n' "$NOT_PR" | awk -F'\t' '$4 == "yes" { print $3 }' | tr '|' '\n')"

# names <root>: the check names the workflows of the tree produce, one per line with the
# file that produces it; and one line per offence of the event rule.
names() { # $1=root
	python3 -I - "$1" "$HERE/tests/fixtures/ci/workflow-files.py" "$NOT_PR" <<'PY'
import sys

root, helper = sys.argv[1:3]
exec(open(helper).read())
TABLE = {row.split("\t")[0]: (row.split("\t")[1], row.split("\t")[2].split("|")) for row in sys.argv[3].split("\n")}
INNER = {}
for path in enumerate_files(root):
    if path.startswith(".github/workflows/reusable-") and path.endswith(".yml"):
        spec = load(root, path)
        INNER[path.rsplit("/", 1)[1]] = [str((job or {}).get("name", job_id)) for job_id, job in (spec.get("jobs") or {}).items()]
for path in enumerate_files(root):
    if not path.startswith(".github/workflows/") or path.rsplit("/", 1)[1].startswith("reusable-"):
        continue
    spec = load(root, path)
    events = triggers(spec)
    allowed = {"pull_request"}
    if path.rsplit("/", 1)[1] in TABLE:
        allowed = set(TABLE[path.rsplit("/", 1)[1]][0].split())
    if events != allowed:
        print(f"OFFENCE {path}: runs on {', '.join(sorted(events)) or 'nothing'}, not on pull_request alone")
    for job_id, job in (spec.get("jobs") or {}).items():
        uses = str(job.get("uses", ""))
        if uses.startswith("./.github/workflows/"):
            for inner in INNER.get(uses.rsplit("/", 1)[1], ["?"]):
                print(f"NAME {job_id} / {inner}\t{path}")
        else:
            print(f"NAME {job.get('name', job_id)}\t{path}")
PY
}

offences() { # $1=root: the offences, then the duplicated names, then a difference from the list
	local out
	out="$(names "$1")"
	printf '%s\n' "$out" | grep '^OFFENCE ' | sed 's/^OFFENCE //' || true
	printf '%s\n' "$out" | grep '^NAME ' | sed 's/^NAME //' | cut -f1 | sort | uniq -d | sed 's/^/produced more than once: /' || true
	printf '%s\n' "$out" | grep '^NAME ' | sed 's/^NAME //' | while IFS=$'\t' read -r name file; do
		owner="$(printf '%s\n' "$NOT_PR" | awk -F'\t' -v n="$name" '{ split($3, names, "|"); for (i in names) if (names[i] == n) print $1 }')"
		if [ -n "$owner" ] && [ "${file##*/}" != "$owner" ]; then echo "a check of $owner produced outside it: $name"; fi
	done
	local produced
	produced="$(printf '%s\n' "$out" | grep '^NAME ' | sed 's/^NAME //' | cut -f1 | sort -u)"
	# A required name has to be produced, the names of the rows marked required among them; a name of any other row may be absent (its
	# workflow may not exist yet) but nothing else may be extra.
	comm -23 <(printf '%s\n%s\n' "$REQUIRED" "$NOT_PR_REQUIRED" | sort -u) <(printf '%s\n' "$produced") | sed 's/^/missing from the workflows: /'
	comm -13 <(printf '%s\n%s\n' "$REQUIRED" "$NOT_PR_NAMES" | sort -u) <(printf '%s\n' "$produced") | sed 's/^/not in the list of required names: /' || true
}

mk() { # <name> <relative workflow file> <text>
	mkdir -p "$WORK/$1/.github/workflows"
	printf '%s\n' "$3" > "$WORK/$1/.github/workflows/$2"
	echo "$WORK/$1"
}
# A copy of this repository's workflows to plant changes in.
cp_repo() { # <name>
	mkdir -p "$WORK/$1/.github"
	cp -r "$HERE/.github/workflows" "$WORK/$1/.github/workflows"
	echo "$WORK/$1"
}

check "the workflows of this repository produce exactly the listed names, each once, on pull_request alone" "" "$(offences "$HERE")"

d="$(cp_repo push)"
sed -i 's/^on:$/on:\n  push:\n    branches: [main]/' "$d/.github/workflows/tests.yml"
check "a push trigger on the workflow is reported" "1" "$(offences "$d" | grep -c 'tests.yml: runs on pull_request, push, not on pull_request alone')"

d="$(cp_repo schedule)"
sed -i 's/^on:$/on:\n  schedule:\n    - cron: "0 0 * * *"/' "$d/.github/workflows/tests.yml"
check "a schedule trigger is reported" "1" "$(offences "$d" | grep -c 'runs on pull_request, schedule')"

d="$(cp_repo second)"
printf 'on: pull_request\njobs:\n  gate:\n    runs-on: x\n    steps: []\n' > "$d/.github/workflows/other.yml"
check "a second workflow that produces the name gate is reported" "produced more than once: gate" "$(offences "$d" | grep 'produced')"

d="$(cp_repo renamed)"
sed -i 's/^    name: gate$/    name: verdict/' "$d/.github/workflows/tests.yml"
check "a renamed gate is reported on both sides of the list" \
	"$(printf 'missing from the workflows: gate\nnot in the list of required names: verdict')" "$(offences "$d")"

d="$(cp_repo analysis)"
printf 'on: pull_request\njobs:\n  a:\n    name: Analyze (actions)\n    runs-on: x\n    steps: []\n' > "$d/.github/workflows/other.yml"
check "a check of the analysis produced by another workflow is reported" "1" "$(offences "$d" | grep -c 'a check of codeql.yml produced outside it: Analyze (actions)')"
d="$(cp_repo codeql-dispatch)"
sed -i 's/^  schedule:$/  workflow_dispatch:\n  schedule:/' "$d/.github/workflows/codeql.yml"
check "a manual trigger on codeql.yml is reported" "1" "$(offences "$d" | grep -c 'codeql.yml: runs on')"
d="$(cp_repo no-codeql)"
rm "$d/.github/workflows/codeql.yml"
check "removing codeql.yml leaves both analysis names missing" "$(printf 'missing from the workflows: Analyze (actions)\nmissing from the workflows: Analyze (python)')" "$(offences "$d")"
d="$(cp_repo no-freshness)"
rm "$d/.github/workflows/freshness.yml"
check "removing freshness.yml leaves the names of its two watchers missing" "$(printf 'missing from the workflows: freshness-codeql / schedule freshness\nmissing from the workflows: freshness-itself / schedule freshness')" "$(offences "$d")"
d="$(cp_repo one-analysis)"
sed -i 's/^    name: Analyze (python)$/    name: Analyze (py)/' "$d/.github/workflows/codeql.yml"
check "renaming one analysis job leaves its name missing, and the new one is not in the list" \
	"$(printf 'missing from the workflows: Analyze (python)\nnot in the list of required names: Analyze (py)')" "$(offences "$d")"
d="$(cp_repo drop-analysis)"
python3 -I - "$d/.github/workflows/codeql.yml" <<'PYX'
import re, sys
text = open(sys.argv[1]).read()
start = text.index("  analyze-python:")
end = text.find("\n  analyze-", start + 1)
open(sys.argv[1], "w").write(text[:start] + (text[end + 1:] if end >= 0 else ""))
PYX
check "removing the job of the Python analysis leaves its name missing" "missing from the workflows: Analyze (python)" "$(offences "$d")"
d="$(cp_repo no-publish)"
rm "$d/.github/workflows/publish.yml"
check "removing publish.yml leaves its six names missing" "6" "$(offences "$d" | grep -c '^missing from the workflows: ')"
d="$(mk publish-ok publish.yml 'on: [workflow_dispatch]
jobs:
  admit:
    runs-on: x
    steps: []')"
check "publish.yml by hand alone is accepted" "" "$(offences "$d" | grep 'publish.yml' || true)"
d="$(mk publish-cron publish.yml 'on: [schedule, workflow_dispatch]
jobs:
  admit:
    runs-on: x
    steps: []')"
check "a cron on publish.yml is reported until its row of the table says so" "1" "$(offences "$d" | grep -c 'publish.yml: runs on schedule, workflow_dispatch')"
d="$(mk publish-push publish.yml 'on: [workflow_dispatch, push]
jobs:
  admit:
    runs-on: x
    steps: []')"
check "a push trigger on publish.yml is reported" "1" "$(offences "$d" | grep -c 'publish.yml: runs on')"
d="$(mk publish-pr publish.yml 'on: [workflow_dispatch, pull_request]
jobs:
  admit:
    runs-on: x
    steps: []')"
check "a pull_request trigger on publish.yml is reported, since it holds secrets" "1" "$(offences "$d" | grep -c 'publish.yml: runs on')"
d="$(cp_repo name-in-tests)"
sed -i 's/^    name: gate$/    name: publish/' "$d/.github/workflows/tests.yml"
check "the name of a job of publish.yml produced by tests.yml is reported" "1" "$(offences "$d" | grep -c 'a check of publish.yml produced outside it: publish')"
d="$(mk dispatch other.yml 'on: [pull_request, workflow_dispatch]
jobs:
  a:
    runs-on: x
    steps: []')"
check "a manual trigger is reported" "1" "$(offences "$d" | grep -c 'runs on pull_request, workflow_dispatch')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
