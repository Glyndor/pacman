#!/usr/bin/env bash
#
# A job that reads a secret runs only from main, and only on the events that publish. `workflow_dispatch` lets whoever can
# push a branch run the workflow on it, with that branch's copy of every script, and an `if` in the YAML does not stop
# that: the branch edits the YAML too. What does is the deployment policy of an environment (main only), which a job
# names with `environment: publish`, and, against accidents, a first step that fails unless the event is a scheduled or
# manual run on exactly refs/heads/main.
#
# So every job that names a secret (`secrets.X` other than the GITHUB_TOKEN, `secrets: inherit`) carries both, the guard
# as its first step and with the exact form below; a secret held by the whole workflow (`env:` of the workflow) counts as
# held by every job, and is refused. The rule is run over planted workflows first, one for each way round it.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the text of workflows, with ${{ }} meant literally
set -euo pipefail

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

audit() { # $1=workflows dir: one line per offence
	python3 -I - "$1" <<'PY'
import glob
import os
import re
import sys

import yaml

GUARD_EVENTS = "case \"$EVENT\" in schedule | workflow_dispatch) ;; *)"
GUARD_REF = '[ "$REF" = refs/heads/main ]'
SECRET = re.compile(r"\$\{\{[^}]*\bsecrets\.(?!GITHUB_TOKEN\b)[A-Za-z0-9_]+")
files = sorted(glob.glob(os.path.join(sys.argv[1], "*.y*ml")))
if not files:
    print("no workflow was read, so nothing was judged")
for path in files:
    name = os.path.basename(path)
    with open(path) as fh:
        spec = yaml.safe_load(fh) or {}
    if SECRET.search(yaml.dump({k: v for k, v in spec.items() if k != "jobs"})):
        print(f"{name}: a secret is named outside any job, so every job holds it")
    for job_id, job in (spec.get("jobs") or {}).items():
        text = yaml.dump(job)
        holds = bool(SECRET.search(text)) or job.get("secrets") == "inherit"
        if not holds:
            continue
        if job.get("environment") != "publish":
            print(f"{name}: job {job_id} reads a secret and does not declare environment: publish")
        steps = job.get("steps") or []
        first = (steps[0].get("run") or "") if steps and isinstance(steps[0], dict) else ""
        env = (steps[0].get("env") or {}) if steps and isinstance(steps[0], dict) else {}
        guard_ok = (
            GUARD_EVENTS in first and GUARD_REF in first and "exit 1" in first
            and env.get("EVENT") == "${{ github.event_name }}" and env.get("REF") == "${{ github.ref }}"
            and "if" not in steps[0]
        )
        if not guard_ok:
            print(f"{name}: job {job_id} reads a secret and its first step is not the guard of event and ref")
PY
}
plant() { # <name> <workflow text>
	mkdir -p "$WORK/$1"
	printf '%s\n' "$2" > "$WORK/$1/w.yml"
	echo "$WORK/$1"
}
GUARD='      - name: Refuse any event or ref that is not allowed
        env:
          EVENT: ${{ github.event_name }}
          REF: ${{ github.ref }}
        run: |
          set -euo pipefail
          case "$EVENT" in schedule | workflow_dispatch) ;; *) echo no; exit 1 ;; esac
          [ "$REF" = refs/heads/main ] || { echo no; exit 1; }'
job() { # <environment line> <guard> <extra step>
	printf 'jobs:\n  j:\n    runs-on: x\n%s    steps:\n%s\n      - run: echo\n        env:\n          K: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}\n%s\n' "$1" "$2" "$3"
}
ENV='    environment: publish
'
check "a job with the environment and the guard first passes" "" "$(audit "$(plant ok "$(job "$ENV" "$GUARD" '')")")"
check "a job with no secret needs neither" "" "$(audit "$(plant none 'jobs:
  j:
    runs-on: x
    steps:
      - run: echo ${{ secrets.GITHUB_TOKEN }}')")"
check "no environment is reported" "w.yml: job j reads a secret and does not declare environment: publish" "$(audit "$(plant noenv "$(job '' "$GUARD" '')")")"
check "another environment is reported" "w.yml: job j reads a secret and does not declare environment: publish" "$(audit "$(plant otherenv "$(job '    environment: staging
' "$GUARD" '')")")"
check "no guard is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" "$(audit "$(plant noguard "$(job "$ENV" '      - run: echo hi' '')")")"
check "a guard that is not the first step is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant late "$(job "$ENV" '      - run: echo first
'"$GUARD" '')")")"
check "a guard that lets another event through is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant event "$(job "$ENV" "${GUARD/schedule | workflow_dispatch/schedule | workflow_dispatch | push}" '')")")"
check "a guard that names another ref is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant ref "$(job "$ENV" "${GUARD/refs\/heads\/main/refs\/heads\/develop}" '')")")"
check "a guard that does not fail is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant nofail "$(job "$ENV" "${GUARD//exit 1/exit 0}" '')")")"
check "a guard that reads another event than the run's is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant evar "$(job "$ENV" "${GUARD/\$\{\{ github.event_name \}\}/schedule}" '')")")"
check "a guard with an if on its own step is reported" "w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant stepif "$(job "$ENV" "${GUARD/      - name: Refuse any event or ref that is not allowed/      - if: false
        name: Refuse any event or ref that is not allowed}" '')")")"
check "a secret named by the workflow, held by every job, is reported" "w.yml: a secret is named outside any job, so every job holds it" \
	"$(audit "$(plant top "env:
  K: \${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}
jobs:
  j: {runs-on: x, steps: []}")")"
check "secrets: inherit on a caller is a secret held" "w.yml: job j reads a secret and does not declare environment: publish
w.yml: job j reads a secret and its first step is not the guard of event and ref" \
	"$(audit "$(plant inherit 'jobs:
  j:
    uses: ./.github/workflows/x.yml
    secrets: inherit')")"
check "a directory with no workflow is not a pass" "no workflow was read, so nothing was judged" "$(audit "$WORK/missing")"

real="$(audit "$HERE/.github/workflows")"
check "every job of this repository that reads a secret has the environment and the guard" "" "$real"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
