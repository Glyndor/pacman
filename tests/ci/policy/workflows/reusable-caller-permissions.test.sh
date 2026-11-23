#!/usr/bin/env bash
#
# A job that calls a reusable workflow can give the called jobs no more than it has, and a reusable job that asks for a scope its
# caller does not grant fails when it starts, not when it is written. So every job that calls a local reusable workflow has to grant,
# by its own `permissions` or by the ones of its workflow, at least what the jobs of the reusable ask for: `permissions: {}` on the
# workflow and nothing on the caller leaves a reusable that wants `contents: read` with nothing. A caller that states nothing at all is
# reported too, since the default of the repository would decide.
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

audit() { # $1=root with .github/workflows: one line per offence
	python3 -I - "$1" <<'PY'
import glob
import os
import sys

import yaml

LEVEL = {"none": 0, "read": 1, "write": 2}
root = sys.argv[1]
folder = os.path.join(root, ".github", "workflows")
files = sorted(glob.glob(os.path.join(folder, "*.y*ml")))
if not files:
    print("no workflow was read, so nothing was judged")


def scopes(node, what):
    """{scope: level} of a permissions value; None when it is not stated; anything unreadable is a failure."""
    if node is None:
        return None
    if node == {}:
        return {}
    if isinstance(node, str):
        if node in ("read-all", "write-all"):
            return {"*": LEVEL["read" if node == "read-all" else "write"]}
        raise ValueError(f"{what} says {node!r}")
    if not isinstance(node, dict):
        raise ValueError(f"{what} is not a map")
    out = {}
    for scope, level in node.items():
        if str(level) not in LEVEL:
            raise ValueError(f"{what} gives {scope!r} the level {level!r}")
        out[str(scope)] = LEVEL[str(level)]
    return out


def asked(name):
    """What the jobs of a reusable workflow ask for, the largest level of each scope."""
    path = os.path.join(folder, name)
    with open(path) as fh:
        spec = yaml.safe_load(fh)
    top = scopes(spec.get("permissions"), f"{name} permissions")
    need = {}
    for job_id, job in (spec.get("jobs") or {}).items():
        own = scopes(job.get("permissions"), f"{name} job {job_id}") if "permissions" in job else top
        if own is None:
            raise ValueError(f"{name} job {job_id} states no permissions")
        for scope, level in own.items():
            need[scope] = max(need.get(scope, 0), level)
    return need


for path in files:
    name = os.path.basename(path)
    try:
        with open(path) as fh:
            spec = yaml.safe_load(fh) or {}
        top = scopes(spec.get("permissions"), f"{name} permissions")
        for job_id, job in (spec.get("jobs") or {}).items():
            uses = str(job.get("uses", ""))
            if not uses.startswith("./.github/workflows/"):
                continue
            granted = scopes(job.get("permissions"), f"{name} job {job_id}") if "permissions" in job else top
            if granted is None:
                print(f"{name}: job {job_id} calls {uses} and neither it nor the workflow states permissions, so the default of the repository decides")
                continue
            need = asked(os.path.basename(uses))
            for scope, level in sorted(need.items()):
                have = max(granted.get(scope, 0), granted.get("*", 0))
                if level > have:
                    word = {1: "read", 2: "write"}[level]
                    print(f"{name}: job {job_id} calls {uses}, which asks for {scope}: {word}, and the caller does not grant it")
    except (ValueError, OSError, yaml.YAMLError) as exc:
        print(f"{name}: cannot be judged ({exc}), and fails")
PY
}
mk() { # <name> <file> <text>
	mkdir -p "$WORK/$1/.github/workflows"
	printf '%s\n' "$3" > "$WORK/$1/.github/workflows/$2"
}
REUSABLE='on:
  workflow_call:
permissions: {}
jobs:
  r:
    runs-on: x
    permissions:
      contents: read
    steps: []'
mk ok r.yml "$REUSABLE"
mk ok c.yml 'on: push
permissions: {}
jobs:
  j:
    permissions:
      contents: read
    uses: ./.github/workflows/r.yml'
check "a caller that grants what the reusable asks for passes" "" "$(audit "$WORK/ok")"
mk none r.yml "$REUSABLE"
mk none c.yml 'on: push
permissions: {}
jobs:
  j:
    uses: ./.github/workflows/r.yml'
check "a caller under permissions: {} that grants nothing is reported" "c.yml: job j calls ./.github/workflows/r.yml, which asks for contents: read, and the caller does not grant it" "$(audit "$WORK/none")"
mk wf r.yml "$REUSABLE"
mk wf c.yml 'on: push
permissions:
  contents: read
jobs:
  j:
    uses: ./.github/workflows/r.yml'
check "a caller that inherits contents: read from its workflow passes" "" "$(audit "$WORK/wf")"
mk empty r.yml "$REUSABLE"
mk empty c.yml 'on: push
jobs:
  j:
    permissions: {}
    uses: ./.github/workflows/r.yml'
check "a job with an empty map of its own is reported" "c.yml: job j calls ./.github/workflows/r.yml, which asks for contents: read, and the caller does not grant it" "$(audit "$WORK/empty")"
mk silent r.yml "$REUSABLE"
mk silent c.yml 'on: push
jobs:
  j:
    uses: ./.github/workflows/r.yml'
check "a caller that states nothing anywhere is reported" "c.yml: job j calls ./.github/workflows/r.yml and neither it nor the workflow states permissions, so the default of the repository decides" "$(audit "$WORK/silent")"
mk write r.yml 'on:
  workflow_call:
permissions: {}
jobs:
  r:
    runs-on: x
    permissions:
      contents: read
      security-events: write
    steps: []'
mk write c.yml 'on: push
permissions: {}
jobs:
  j:
    permissions:
      contents: read
      security-events: read
    uses: ./.github/workflows/r.yml'
check "a caller that grants read where the reusable asks for write is reported" "c.yml: job j calls ./.github/workflows/r.yml, which asks for security-events: write, and the caller does not grant it" "$(audit "$WORK/write")"
mk wide r.yml "$REUSABLE"
mk wide c.yml 'on: push
jobs:
  j:
    permissions: write-all
    uses: ./.github/workflows/r.yml'
check "write-all covers it" "" "$(audit "$WORK/wide")"
mk bad r.yml "$REUSABLE"
mk bad c.yml 'on: push
jobs:
  j:
    permissions: {contents: maybe}
    uses: ./.github/workflows/r.yml'
check "a level that is not one is a workflow that cannot be judged, and fails" "1" "$(audit "$WORK/bad" | grep -c 'cannot be judged')"
mk nofile c.yml 'on: push
permissions: {}
jobs:
  j:
    permissions: {contents: read}
    uses: ./.github/workflows/missing.yml'
check "a reusable that is not there fails" "1" "$(audit "$WORK/nofile" | grep -c 'cannot be judged')"
mkdir -p "$WORK/emptydir/.github/workflows"
check "a folder with no workflow is not a pass" "no workflow was read, so nothing was judged" "$(audit "$WORK/emptydir")"

real="$(audit "$HERE")"
check "every caller of a local reusable workflow of this repository grants what it asks for" "" "$real"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
