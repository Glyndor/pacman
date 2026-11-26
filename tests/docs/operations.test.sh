#!/usr/bin/env bash
#
# docs/operations.md says how the repository publishes itself. Each fact it states that the workflows can contradict is tied here
# to them: the jobs of publish.yml, what each needs and which of them declare the environment, the secrets it names against the
# ones the workflow reads, the trigger of each workflow, the schedules, and every path it cites against the tree. A guide that
# said something else would be believed over the workflows, and it is the one document that tells an operator where the
# secrets go. Each check is shown failing against a planted copy of the guide first.
#
# Requires: python3 with PyYAML.
# The planted copies are made with sed expressions that carry backticks the guide holds literally.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"

# offences <guide>: one line per statement of the guide that the workflows or the tree contradict
offences() {
	python3 -I - "$1" "$HERE" <<'PY'
import os
import re
import sys

import yaml

guide, here = sys.argv[1:3]
text = open(guide).read()
wf = os.path.join(here, ".github/workflows")


def load(name):
    with open(os.path.join(wf, name)) as fh:
        return yaml.safe_load(fh)


def on(spec):
    return spec.get(True, spec.get("on")) or {}


pub = load("publish.yml")
jobs = pub["jobs"]
out = []

# the table of the jobs of a publication: | `job` | needs | ... | holds |
section = text.split("## The jobs of a publication")[1].split("## ")[0]
rows = {}
for line in section.splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) == 4 and cells[0].startswith("`") and cells[0] != "`job`":
        rows[cells[0].strip("`")] = cells
for job in jobs:
    if job not in rows:
        out.append(f"publish.yml has the job {job}, which the guide does not list")
for job, cells in rows.items():
    if job not in jobs:
        out.append(f"the guide lists the job {job}, which publish.yml does not have")
        continue
    needs = jobs[job].get("needs", [])
    needs = [needs] if isinstance(needs, str) else list(needs)
    said = re.findall(r"`([^`]+)`", cells[1])
    if sorted(said) != sorted(needs):
        out.append(f"{job} needs {needs} in publish.yml and {said} in the guide")
    secrets = sorted(set(re.findall(r"secrets\.([A-Z0-9_]+)", yaml.safe_dump(jobs[job]))))
    held = sorted(re.findall(r"`([A-Z][A-Z0-9_]+)`", cells[3]))
    if secrets != held:
        out.append(f"{job} reads the secrets {secrets} in publish.yml and the guide names {held}")
for job in jobs:
    if job in rows:
        env = jobs[job].get("environment")
        if (env == "publish") != (job in ("sign", "publish")):
            out.append(f"{job} declares the environment {env}, and the guide says that only sign and publish do")

# the guards the guide says each job carries
for job in ("admit", "build", "sign", "publish"):
    steps = [st.get("name") for st in jobs[job]["steps"]]
    if "Refuse any event or ref that is not allowed" not in steps:
        out.append(f"{job} has no step that refuses an event or a ref that is not allowed, and the guide says that it has")
for job in jobs:
    steps = [st.get("name") for st in jobs[job].get("steps", [])]
    if ("Refuse a re-run" in steps) != (job in ("sign", "publish")):
        out.append(f"{job} does not refuse a re-run exactly as the guide says (sign and publish)")
if "first_publication" not in on(pub)["workflow_dispatch"]["inputs"]:
    out.append("publish.yml has no input first_publication, which the guide names")

# the triggers
if list(on(pub)) != ["workflow_dispatch"]:
    out.append(f"publish.yml runs on {list(on(pub))}, and the guide says that it runs by hand only")
if "schedule" in on(pub):
    out.append("publish.yml has a schedule, and the guide says that it has none yet")
for name in ("verify-live.yml", "rehearsal.yml"):
    if list(on(load(name))) != ["workflow_dispatch"]:
        out.append(f"{name} runs on {list(on(load(name)))}, and the guide says that it runs by hand")
for name, cron in (("codeql.yml", "23 5 * * 1"), ("freshness.yml", "13 8,20 * * *")):
    crons = [s["cron"] for s in on(load(name)).get("schedule", [])]
    if crons != [cron]:
        out.append(f"{name} is scheduled at {crons}, and the guide says {cron}")
if not re.search(r"Mondays 05:23 UTC", text) or not re.search(r"08:13 and 20:13 UTC", text):
    out.append("the guide does not say the hours of the two schedules")
if "concurrency: publish-pacman" not in text or pub["concurrency"]["group"] != "publish-pacman" or pub["concurrency"]["cancel-in-progress"] is not False:
    out.append("the concurrency group of publish.yml is not the one the guide says, or a run in flight is cancelled")
for key in ("BUCKET", "ARCHIVE_URL"):
    value = pub["env"][key]
    if value not in text:
        out.append(f"the guide does not name {key} of publish.yml, {value}")
for name in ("tests.yml", "codeql.yml", "freshness.yml", "verify-live.yml", "rehearsal.yml", "publish.yml"):
    if f"`{name}`" not in text:
        out.append(f"the guide does not name {name}")
for name in sorted(os.listdir(wf)):
    if not name.startswith("reusable-") and f"`{name}`" not in text:
        out.append(f"the workflow {name} is not in the guide")

# every path the guide cites exists
for path in sorted(set(re.findall(r"`((?:\.github|scripts|tests|keyring|docs)/[A-Za-z0-9_./-]+)`", text))):
    if "<" in path:
        continue
    if not os.path.exists(os.path.join(here, path.rstrip("/"))):
        out.append(f"the guide cites {path}, which is not in the repository")
for target in re.findall(r"\]\(([^)#]+)\)", text):
    if not target.startswith("http") and not os.path.exists(os.path.normpath(os.path.join(here, "docs", target))):
        out.append(f"the guide links {target}, which is not in the repository")
print("\n".join(out))
PY
}

GUIDE="$HERE/docs/operations.md"
check "the guide agrees with the workflows and with the tree" "" "$(offences "$GUIDE")"

plant() { # <name> <sed expression>: a copy of the guide with one statement changed
	sed "$2" "$GUIDE" > "$WORK/$1.md"
}
plant needs 's/| `build` | `admit` |/| `build` | `admit`, `sign` |/'
check "a job that waits for another one than publish.yml says is reported" "1" "$(offences "$WORK/needs.md" | grep -c '^build needs')"
plant secret 's/`GLYNDOR_CF_ZONE_ID`/`GLYNDOR_CF_ZONE`/'
check "a secret that the workflow does not read is reported" "1" "$(offences "$WORK/secret.md" | grep -c '^publish reads the secrets')"
plant nosecret 's/| `GLYNDOR_PACMAN_GPG_PRIVATE_KEY` |/| no secret |/'
check "a secret that the guide leaves out is reported" "1" "$(offences "$WORK/nosecret.md" | grep -c '^sign reads the secrets')"
plant job 's/^| `verify` | `publish` |/| `check` | `publish` |/'
check "a job that publish.yml does not have is reported, and so is one the guide leaves out" "2" "$(offences "$WORK/job.md" | grep -c -e 'does not have' -e 'does not list')"
plant path 's|`scripts/sign/`|`scripts/signing/`|'
check "a path that is not in the repository is reported" "1" "$(offences "$WORK/path.md" | grep -c 'scripts/signing/')"
plant cron 's/Mondays 05:23 UTC/Tuesdays 05:23 UTC/'
check "a schedule that is not the one of the workflow is reported" "1" "$(offences "$WORK/cron.md" | grep -c 'hours of the two schedules')"
check "the guide still names the first_publication input" "1" "$(grep -c 'first_publication' "$GUIDE")"
plant bucket 's/glyndor-pacman/glyndor-other/'
check "a bucket that is not the one of publish.yml is reported" "1" "$(offences "$WORK/bucket.md" | grep -c 'BUCKET')"
plant workflow 's/`rehearsal.yml`/`rehearsals.yml`/g'
check "a workflow that the guide does not name is reported, in each of the two ways" "2" "$(offences "$WORK/workflow.md" | grep -c 'rehearsal.yml')"

finish
