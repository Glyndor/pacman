#!/usr/bin/env python3
"""The audit of the tests that judge secrets and the guard of a publication job: one line per offence, over the workflows of a folder.

  secret-audit.py <folder with workflows>

Shared by the suites tests/ci/policy/workflows/secret-jobs-*.test.sh; it is not a suite. The rules are written in the first of them.
"""
import glob
import os
import re
import sys

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode

# The guard, whole: the first step of a job that holds a secret is exactly this, once normalised (no key but name, env and run).
CANON_ENV = {"EVENT": "${{ github.event_name }}", "REF": "${{ github.ref }}"}
CANON_RUN = "\n".join([
    "set -euo pipefail",
    'case "$EVENT" in schedule | workflow_dispatch) ;; *) echo "::error::$EVENT is not an event this workflow runs on"; exit 1 ;; esac',
    '[ "$REF" = refs/heads/main ] || { echo "::error::$REF is not refs/heads/main"; exit 1; }',
])
# The variables that a workflow, or a job that holds a secret, may set for every step: any other can change how the shell or the
# guard runs (BASH_ENV, ENV, PATH, SHELLOPTS, BASHOPTS, LD_PRELOAD, BASH_FUNC_*, EVENT, REF...).
ALLOWED_ENV = {"ARCHIVE_URL", "BUCKET", "FINGERPRINT"}
# The keys that a job that holds a secret may have, and each one is here for a reason; any other (services, strategy, uses, with,
# secrets, outputs, defaults, container, continue-on-error...) is refused, because it can start something before the guard, change
# how it runs, or hand a secret on to a workflow that is not read here. `defaults`, `container` and `continue-on-error` keep their
# own messages below.
JOB_KEYS = {
    "name": "the name of the check",
    "needs": "the jobs it waits for",
    "runs-on": "the runner",
    "environment": "publish, whose deployment policy is main only",
    "permissions": "the scopes of the token",
    "timeout-minutes": "the bound of every job",
    "concurrency": "two publications do not run at once",
    "env": "only the closed list of names",
    "steps": "what it runs",
}
SPECIAL_JOB_KEYS = {"continue-on-error", "defaults", "container"}
# The keys of a step after the guard: the guard itself is compared whole. `shell`, `working-directory` and `continue-on-error`
# are not here: they change how a step runs or whether its failure counts.
STEP_KEYS = {"name", "id", "env", "run", "uses", "with", "if", "timeout-minutes"}
# An `if` is an expression and is not analysed: a job that holds a secret, and each step after the guard, carries none unless its
# whole value is exactly one of these texts. Nothing needs one today, so the list is empty and `if` is forbidden there.
SAFE_IFS = set()
LOCAL_ACTION = re.compile(r"\./[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*")
# The actions a step of such a job may use, exactly as pinned, each with the reason it is safe: the guard is the first step, and
# an action with a `pre` hook would run before it. Checked in the action.yml of each commit: none has `pre`. A local action
# (./...) is read in this repository and is allowed; docker://, a tag, another commit and any other action are not.
ALLOWED_USES = {
    "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1": "v7.0.1: runs main and a post step that cleans up, no pre",
    "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333": "v8.0.2: runs main only",
    "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9": "v7.0.2: runs main only",
}
STRING = re.compile(r"'(?:[^']|'')*'|\"(?:[^\"\\]|\\.)*\"")
CORE = {"tag:yaml.org,2002:" + t for t in ("str", "int", "float", "bool", "null", "map", "seq", "timestamp", "merge")}


class Unreadable(Exception):
    pass


def scalars(node, seen=None):
    """Every scalar of a composed document, the keys among them, as written. A node this does not know is a failure."""
    seen = set() if seen is None else seen
    if id(node) in seen:
        return
    seen.add(id(node))
    if node.tag not in CORE:
        raise Unreadable(f"a node with the tag {node.tag}")
    if isinstance(node, ScalarNode):
        yield node.value
    elif isinstance(node, MappingNode):
        for key, value in node.value:
            yield from scalars(key, seen)
            yield from scalars(value, seen)
    elif isinstance(node, SequenceNode):
        for value in node.value:
            yield from scalars(value, seen)
    else:
        raise Unreadable(f"a node of the kind {type(node).__name__}")


def expressions(text):
    """The bodies of the ${{ ... }} of a text, reading quoted strings, so that a `}}` inside one does not end the expression."""
    i = 0
    while True:
        start = text.find("${{", i)
        if start < 0:
            return
        j, quote = start + 3, None
        while j < len(text):
            c = text[j]
            if quote:
                if c == quote:
                    if text[j + 1:j + 2] == quote:
                        j += 2
                        continue
                    quote = None
            elif c in "'\"":
                quote = c
            elif text.startswith("}}", j):
                break
            j += 1
        else:
            yield text[start + 3:]
            return
        yield text[start + 3:j]
        i = j + 2


def holds_secret(expression):
    """True for any reference to the secrets context that is not exactly secrets.GITHUB_TOKEN."""
    bare = STRING.sub("''", expression)
    for match in re.finditer(r"(?<![\w.$-])secrets(?![\w-])", bare, re.I):
        rest = bare[match.end():]
        exact = match.group(0) == "secrets" and re.match(r"\.GITHUB_TOKEN(?![\w-])", rest)
        if not exact:
            return True
    return False


def text_holds(text):
    return any(holds_secret(e) for e in expressions(text))


def normal(text):
    return "\n".join(line.rstrip() for line in str(text).replace("\r\n", "\n").strip("\n").split("\n"))


def shell_default(spec):
    return ((spec.get("defaults") or {}).get("run") or {}).get("shell")


def own_ifs(job):
    """The `if` of the job and of each of its steps: expressions with or without the braces, judged wrapped as well as raw."""
    found = [job.get("if")] + [step.get("if") for step in (job.get("steps") or []) if isinstance(step, dict)]
    return ["${{ " + value + " }}" for value in found if isinstance(value, str)]


def env_names(node, what):
    if node is None:
        return set()
    if not isinstance(node, dict):
        raise Unreadable(f"{what} is not a map, so what it sets cannot be read")
    return set(map(str, node))


files = sorted(glob.glob(os.path.join(sys.argv[1], "*.y*ml")))
if not files:
    print("no workflow was read, so nothing was judged")
for path in files:
    name = os.path.basename(path)
    try:
        with open(path) as fh:
            loader = yaml.SafeLoader(fh.read())
        try:
            root = loader.get_single_node()
            if not isinstance(root, MappingNode):
                raise Unreadable("it is not a map at its top")
            spec = loader.construct_document(root)
            job_nodes, outside = [], []
            for key, value in root.value:
                if key.value == "jobs" and isinstance(value, MappingNode):
                    job_nodes = list(value.value)
                else:
                    outside.extend(scalars(key))
                    outside.extend(scalars(value))
            # One representation of a key: the one the document is built with (`yes`, `on`, `null` and `1` are not strings there),
            # so the node of a job and the job it was built into are matched by the same key, and a difference is a failure.
            texts = {}
            for key_node, value_node in job_nodes:
                key = loader.construct_object(key_node, deep=True)
                if key in texts:
                    raise Unreadable(f"the job {key!r} is written twice")
                texts[key] = list(scalars(key_node)) + list(scalars(value_node))
        finally:
            loader.dispose()
        jobs = spec.get("jobs") if "jobs" in spec else {}
        if jobs is None:
            jobs = {}
        if not isinstance(jobs, dict):
            raise Unreadable("jobs is not a map")
        if set(texts) != set(jobs):
            raise Unreadable("the jobs of the nodes and the jobs of the document are not the same set (a merge key, or a key read twice)")
        wf_env = env_names(spec.get("env"), "the env of the workflow")
        job_env = {j: env_names(job.get("env"), f"the env of job {j}") for j, job in jobs.items() if isinstance(job, dict)}
    except (yaml.YAMLError, Unreadable, OSError) as exc:
        print(f"{name}: cannot be read as a workflow ({str(exc).splitlines()[0]}), so nothing in it is judged and it fails")
        continue
    if any(text_holds(t) for t in outside):
        print(f"{name}: a secret is named outside any job, so every job holds it")
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            print(f"{name}: job {job_id} is not a map, so it cannot be read and it fails")
            continue
        job_env.setdefault(job_id, set())
        # a caller that hands secrets down, by `inherit` or by a map, holds them; an empty map holds none
        holds = any(text_holds(t) for t in texts[job_id]) or any(text_holds(t) for t in own_ifs(job)) or bool(job.get("secrets"))
        if not holds:
            continue
        if job.get("environment") != "publish":
            print(f"{name}: job {job_id} reads a secret and does not declare environment: publish")
        steps = job.get("steps") or []
        first = steps[0] if steps and isinstance(steps[0], dict) else {}
        guard_ok = (
            set(first) <= {"name", "env", "run"} and {"env", "run"} <= set(first)
            and first.get("env") == CANON_ENV and normal(first.get("run")) == CANON_RUN
        )
        if not guard_ok:
            print(f"{name}: job {job_id} reads a secret and its first step is not the guard of event and ref")
        for key in sorted(map(str, set(job) - set(JOB_KEYS) - SPECIAL_JOB_KEYS - {"if"})):
            print(f"{name}: job {job_id} reads a secret and has the key {key}, which a job that holds a secret does not carry")
        for number, step in enumerate(steps[1:], 2):
            if not isinstance(step, dict):
                print(f"{name}: job {job_id} reads a secret and its step {number} is not a map, so it cannot be read")
                continue
            for key in sorted(map(str, set(step) - STEP_KEYS)):
                print(f"{name}: job {job_id} reads a secret and its step {number} has the key {key}, which a step after the guard does not carry")
        if "if" in job and not (isinstance(job["if"], str) and job["if"] in SAFE_IFS):
            print(f"{name}: job {job_id} reads a secret and has an if ({job['if']!r}), which no job that holds a secret may carry")
        for number, step in enumerate(steps[1:], 2):
            if not isinstance(step, dict):
                continue
            if "if" in step and not (isinstance(step["if"], str) and step["if"] in SAFE_IFS):
                print(f"{name}: job {job_id} reads a secret and its step {number} has an if ({step['if']!r}), which a step after the guard may not carry")
            if "uses" in step and (not isinstance(step["uses"], str) or (step["uses"] not in ALLOWED_USES and not (LOCAL_ACTION.fullmatch(step["uses"]) and not {".", ".."} & set(step["uses"].split("/")[1:])))):
                print(f"{name}: job {job_id} reads a secret and its step {number} uses {step['uses']!r}, which is not on the closed list of actions with no pre hook")
        if "continue-on-error" in job:
            print(f"{name}: job {job_id} reads a secret and sets continue-on-error, which lets a failed guard pass")
        if shell_default(job) or shell_default(spec):
            print(f"{name}: job {job_id} reads a secret and a default shell is set, which changes how the guard runs")
        for var in sorted((wf_env | job_env[job_id]) - ALLOWED_ENV):
            print(f"{name}: job {job_id} reads a secret and the workflow or the job sets {var} for every step, which can change how the guard runs")
        if "container" in job:
            print(f"{name}: job {job_id} reads a secret and runs in a container, which is not the runner whose shell the guard is written for")
