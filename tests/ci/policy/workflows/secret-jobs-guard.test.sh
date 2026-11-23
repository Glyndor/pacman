#!/usr/bin/env bash
#
# The rule of secret-jobs-are-guarded.test.sh, over the first step of a job that holds a secret (the guard, compared whole) and
# over what the steps inherit (env, container, a default shell, continue-on-error) and the closed list of keys of the job and of its steps.
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the text of workflows, with ${{ }} meant literally
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/ci/secret-plants.sh"

echo "-- the guard is the whole first step, and nothing is added around it"
NOGUARD="w.yml: job j reads a secret and its first step is not the guard of event and ref"
guard_with() { # <extra lines of the step, after run>
	printf '%s\n%s' "$GUARD" "$1"
}
check "a guard with another name passes, the name is free" "" "$(audit "$(plant renamed "$(job "$ENV" "${GUARD/Refuse any event or ref that is not allowed/A name of my own}" '')")")"
for extra in '        shell: bash' '        working-directory: /tmp' '        continue-on-error: true' '        timeout-minutes: 1' '        id: guard'; do
	check "a guard step with '${extra//[ ]/}' is reported" "$NOGUARD" "$(audit "$(plant "step$RANDOM" "$(job "$ENV" "$(guard_with "$extra")" '')")")"
done
check "a guard with one more variable in env is reported" "$NOGUARD" "$(audit "$(plant extraenv "$(job "$ENV" "${GUARD/          REF: \$\{\{ github.ref \}\}/          REF: \$\{\{ github.ref \}\}
          EXTRA: x}" '')")")"
check "a guard with no REF in env is reported" "$NOGUARD" "$(audit "$(plant noref "$(job "$ENV" "${GUARD/          REF: \$\{\{ github.ref \}\}/}" '')")")"
check "a guard with a line more in its script is reported" "$NOGUARD" "$(audit "$(plant moreline "$(job "$ENV" "$GUARD
          echo done" '')")")"
check "a guard with a line less in its script is reported" "$NOGUARD" "$(audit "$(plant lessline "$(job "$ENV" "${GUARD/          set -euo pipefail
/}" '')")")"
check "a guard whose message is not the canonical one is reported" "$NOGUARD" "$(audit "$(plant message "$(job "$ENV" "${GUARD/is not an event this workflow runs on/is odd}" '')")")"
check "a uses step in the place of the guard is reported" "$NOGUARD" "$(audit "$(plant usesfirst "$(job "$ENV" '      - uses: actions/checkout@v4' '')")")"
check "continue-on-error on the job is reported" "w.yml: job j reads a secret and sets continue-on-error, which lets a failed guard pass" \
	"$(audit "$(plant jobcoe "$(job '    environment: publish
    continue-on-error: true
' "$GUARD" '')")")"
check "a default shell on the job is reported" "w.yml: job j reads a secret and a default shell is set, which changes how the guard runs" \
	"$(audit "$(plant jobshell "$(job '    environment: publish
    defaults:
      run:
        shell: bash {0}
' "$GUARD" '')")")"
check "a default shell on the workflow is reported" "w.yml: job j reads a secret and a default shell is set, which changes how the guard runs" \
	"$(audit "$(plant wfshell "defaults:
  run:
    shell: sh {0}
$(job "$ENV" "$GUARD" '')")")"
check "a default shell on a workflow with no secret job is not an offence" "" "$(audit "$(plant wfshellnone 'defaults:
  run:
    shell: bash
jobs:
  j:
    runs-on: x
    steps:
      - run: echo')")"

check "BASH_ENV on the workflow is reported" "w.yml: job j reads a secret and the workflow or the job sets BASH_ENV for every step, which can change how the guard runs" \
	"$(audit "$(plant wfenv "env:
  BASH_ENV: /tmp/x
$(job "$ENV" "$GUARD" '')")")"
for var in PATH ENV SHELLOPTS BASHOPTS LD_PRELOAD EVENT REF 'BASH_FUNC_x%%'; do
	check "$var on the job is reported" "1" "$(audit "$(plant "je$RANDOM" "$(job "$ENV    env:
      $var: x
" "$GUARD" '')")" | grep -c "sets $var for every step")"
done
check "the variables the workflow lists as its own are not an offence" "" "$(audit "$(plant wfenvok "env:
  ARCHIVE_URL: https://example.org
  BUCKET: b
  FINGERPRINT: 0EE5C891235BE1CAD2E0ABA477E416B24362E256
$(job "$ENV" "$GUARD" '')")")"
check "an env that is an expression and not a map fails" "1" "$(audit "$(plant envexpr "env: \${{ fromJSON('{}') }}
$(job "$ENV" "$GUARD" '')")" | grep -c 'cannot be read as a workflow')"
check "a container on the job is reported" "w.yml: job j reads a secret and runs in a container, which is not the runner whose shell the guard is written for" \
	"$(audit "$(plant container "$(job "$ENV    container: alpine
" "$GUARD" '')")")"
echo "-- a job that holds a secret has only the keys it needs, and so do its steps"
NOKEY="which a job that holds a secret does not carry"
check "services on the job is reported, since it starts containers before the guard" "w.yml: job j reads a secret and has the key services, $NOKEY" \
	"$(audit "$(plant services "$(job '    environment: publish
    services:
      db:
        image: postgres
' "$GUARD" '')")")"
for key in strategy outputs frobnicate 'timeout: 3' ; do
	check "the key ${key%%:*} on the job is reported" "1" "$(audit "$(plant "jk$RANDOM" "$(job "    environment: publish
    ${key%%:*}: ${key#*: }
" "$GUARD" '')")" | grep -c "has the key ${key%%:*}, $NOKEY")"
done
check "the keys a job with a secret may carry are not an offence" "" "$(audit "$(plant allkeys 'jobs:
  j:
    name: publish
    needs: []
    runs-on: x
    environment: publish
    permissions: {contents: read}
    timeout-minutes: 5
    concurrency: {group: g}
    env: {BUCKET: b}
    steps:
'"$GUARD"'
      - run: echo
        env:
          K: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}')")"
STEPMSG="which a step after the guard does not carry"
for key in shell working-directory continue-on-error frobnicate; do
	check "the key $key on a step after the guard is reported" "1" "$(audit "$(plant "sk$RANDOM" "$(job "$ENV" "$GUARD" "      - run: echo
        $key: x")")" | grep -c "has the key $key, $STEPMSG")"
done
check "the keys a step after the guard may carry are not an offence" "" "$(audit "$(plant stepkeys "$(job "$ENV" "$GUARD" '      - name: n
        id: i
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with: {persist-credentials: false}
        timeout-minutes: 3')")")"
check "a step that is not a map is reported" "1" "$(audit "$(plant stepstr "$(job "$ENV" "$GUARD" '      - just text')")" | grep -c 'is not a map, so it cannot be read')"

check "an env or a container on a job that holds no secret is not an offence" "" "$(audit "$(plant nosecretenv 'env:
  BASH_ENV: /x
jobs:
  j:
    runs-on: x
    container: alpine
    steps:
      - run: echo')")"

finish
