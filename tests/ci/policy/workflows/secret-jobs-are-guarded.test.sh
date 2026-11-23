#!/usr/bin/env bash
#
# A job that reads a secret runs only from main, and only on the events that publish. `workflow_dispatch` lets whoever can
# push a branch run the workflow on it, with that branch's copy of every script, and an `if` in the YAML does not stop
# that: the branch edits the YAML too. What does is the deployment policy of an environment (main only), which a job
# names with `environment: publish`, and, against accidents, a first step that fails unless the event is a scheduled or
# manual run on exactly refs/heads/main.
#
# So every job that holds a secret carries both, the guard as its first step and in exactly the form below. A job holds a secret
# when any expression of it (every `${{ }}` is read by a parser that knows quoted strings, and so is an `if`) refers to the
# `secrets` context in any way but exactly `secrets.GITHUB_TOKEN`: an index, `toJSON(secrets)`, the whole context, a wildcard,
# another capitalisation, spaces around the dot. A caller of a reusable workflow holds them when it passes `secrets:` that is not
# empty, by `inherit` or by a map. A secret held by the whole workflow (`env:` of the workflow) counts as held by every job, and
# is refused. The guard is compared whole, after normalising its text, with a canonical step that has no key but name, env and
# run; `continue-on-error` on the job and a default shell on the job or on the workflow are refused too, since they change how the
# guard runs. An `if` is not analysed (no regular expression of status functions can follow every way to write one): a job that
# holds a secret, and each step after the guard, carries none unless its whole value is on a closed list, which is empty. A `uses`
# in such a job is exactly one of three actions pinned by commit, none with a `pre` hook that would run before the guard, or a
# local action. The rule is run over planted workflows first, one for each way round it.
#
# This suite holds the basic rules; the others are in secret-jobs-forms.test.sh (every way of naming a secret and of writing a job),
# secret-jobs-guard.test.sh (the guard, what the steps inherit, the keys) and secret-jobs-if-and-uses.test.sh (`if` and `uses`).
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the text of workflows, with ${{ }} meant literally
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/ci/secret-plants.sh"

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
check "secrets: inherit on a caller is a secret held, and a caller has keys that a job with a secret does not carry" "w.yml: job j reads a secret and does not declare environment: publish
w.yml: job j reads a secret and its first step is not the guard of event and ref
w.yml: job j reads a secret and has the key secrets, which a job that holds a secret does not carry
w.yml: job j reads a secret and has the key uses, which a job that holds a secret does not carry" \
	"$(audit "$(plant inherit 'jobs:
  j:
    uses: ./.github/workflows/x.yml
    secrets: inherit')")"
check "a directory with no workflow is not a pass" "no workflow was read, so nothing was judged" "$(audit "$WORK/missing")"

real="$(audit "$HERE/.github/workflows")"
check "every job of this repository that reads a secret has the environment and the guard" "" "$real"

finish
