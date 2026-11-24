#!/usr/bin/env bash
#
# A publication is started again, never re-run: a re-run of a job uses the artifacts and the state of the first attempt, which the
# repository may have moved past, and would write them over what is served. So the jobs of publish.yml that hold the signing key and
# the bucket, `sign` and `publish`, have as their second step, right after the guard of event and ref, a step that fails unless
# github.run_attempt is 1. The step is compared whole, by equality, with the canonical one, and the planted workflows below break
# each way round it.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the text of workflows, with ${{ }} meant literally
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

audit() { # $1=a publish.yml: one line per offence
	python3 -I - "$1" <<'PY'
import sys

import yaml

CANON_ENV = {"ATTEMPT": "${{ github.run_attempt }}"}
CANON_RUN = "\n".join([
    "set -euo pipefail",
    "# A re-run would write with the state of the first attempt, which the repository has moved past.",
    '[ "$ATTEMPT" = 1 ] || { echo "::error::this is attempt $ATTEMPT; a publication is started again, not re-run"; exit 1; }',
])
JOBS = ("sign", "publish")


def normal(text):
    return "\n".join(line.rstrip() for line in str(text).replace("\r\n", "\n").strip("\n").split("\n"))


with open(sys.argv[1]) as fh:
    spec = yaml.safe_load(fh) or {}
jobs = spec.get("jobs") or {}
for job_id in JOBS:
    job = jobs.get(job_id)
    if not isinstance(job, dict):
        print(f"job {job_id} is not in the workflow")
        continue
    steps = job.get("steps") or []
    second = steps[1] if len(steps) > 1 and isinstance(steps[1], dict) else {}
    ok = (
        set(second) <= {"name", "env", "run"} and {"env", "run"} <= set(second)
        and second.get("env") == CANON_ENV and normal(second.get("run")) == normal(CANON_RUN)
    )
    if not ok:
        print(f"job {job_id}: its second step is not the refusal of a re-run")
PY
}
plant() { # <name> <second step text for sign> <second step text for publish>
	mkdir -p "$WORK/$1"
	printf 'jobs:\n  sign:\n    steps:\n      - run: guard\n%s\n  publish:\n    steps:\n      - run: guard\n%s\n' "$2" "$3" > "$WORK/$1/publish.yml"
	echo "$WORK/$1/publish.yml"
}
STEP='      - name: Refuse a re-run
        env:
          ATTEMPT: ${{ github.run_attempt }}
        run: |
          set -euo pipefail
          # A re-run would write with the state of the first attempt, which the repository has moved past.
          [ "$ATTEMPT" = 1 ] || { echo "::error::this is attempt $ATTEMPT; a publication is started again, not re-run"; exit 1; }'
check "both jobs with the canonical step pass" "" "$(audit "$(plant ok "$STEP" "$STEP")")"
check "a job with no second step is reported" "job publish: its second step is not the refusal of a re-run" "$(audit "$(plant none "$STEP" '      - run: echo')")"
check "the step in third place is reported, for the job where it is" "job sign: its second step is not the refusal of a re-run" "$(audit "$(plant late '      - run: echo
'"$STEP" "$STEP")")"
check "a check of the attempt that lets a second one through is reported" "job sign: its second step is not the refusal of a re-run" \
	"$(audit "$(plant le "${STEP/ATTEMPT\" = 1/ATTEMPT\" -le 3}" "$STEP")")"
check "a step with an if is reported" "job sign: its second step is not the refusal of a re-run" "$(audit "$(plant if "${STEP/      - name:/      - if: always()
        name:}" "$STEP")")"
check "a step with continue-on-error is reported" "job publish: its second step is not the refusal of a re-run" "$(audit "$(plant coe "$STEP" "$STEP
        continue-on-error: true")")"
check "a step that reads another variable is reported" "job sign: its second step is not the refusal of a re-run" "$(audit "$(plant var "${STEP/github.run_attempt/github.run_number}" "$STEP")")"
check "a step that does not exit is reported" "job publish: its second step is not the refusal of a re-run" "$(audit "$(plant noexit "$STEP" "${STEP/exit 1; \}/exit 0; \}}")")"
check "a workflow with no sign job is reported" "job sign is not in the workflow" "$(mkdir -p "$WORK/nosign"; printf 'jobs:\n  publish:\n    steps:\n      - run: g\n%s\n' "$STEP" > "$WORK/nosign/publish.yml"; audit "$WORK/nosign/publish.yml")"

real="$(audit "$HERE/.github/workflows/publish.yml")"
check "the sign and the publish jobs of this repository refuse a re-run" "" "$real"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
