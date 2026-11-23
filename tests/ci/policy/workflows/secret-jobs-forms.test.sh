#!/usr/bin/env bash
#
# The rule of secret-jobs-are-guarded.test.sh, over every way of naming a secret (an index, toJSON(secrets), the whole context, a
# wildcard, another capitalisation, spaces around the dot, a string with a } inside), over every scalar of the document (the keys
# too, an env variable called if, a tag the parser does not know), and over the key a job is built with (yes, on, null, 1).
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the text of workflows, with ${{ }} meant literally
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/ci/secret-plants.sh"

echo "-- every way of naming a secret is a secret held"
form() { # <expression text>: a job that carries it in an env var, with no environment and no guard
	plant "form$RANDOM" "jobs:
  j:
    runs-on: x
    steps:
      - run: echo
        env:
          K: $1"
}
held() { # <description> <expression>
	check "$1 is a secret held" "1" "$(audit "$(form "$2")" | grep -c 'does not declare environment: publish')"
}
held "an index with quotes" "\${{ secrets['GLYNDOR_PACMAN_GPG_PRIVATE_KEY'] }}"
held "toJSON of the whole context" '${{ toJSON(secrets) }}'
held "the whole context" '${{ secrets }}'
held "a wildcard" '${{ secrets.* }}'
held "another capitalisation of the context" '${{ SECRETS.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}'
held "spaces around the dot" '${{ secrets . GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}'
held "a name that only starts like the token" '${{ secrets.GITHUB_TOKENS }}'
held "a reference after a string that holds }}" "\${{ format('}}', secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY) }}"
held "a reference after a string that holds a }" "\${{ '}' && secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}"
held "a reference in the second expression of a text" 'a ${{ github.sha }} b ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}'
check "an if that reads a secret, with no braces, is a secret held" "1" "$(audit "$(plant ifsecret 'jobs:
  j:
    runs-on: x
    steps:
      - if: secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY != '"'"''"'"'
        run: echo')" | grep -c 'does not declare environment: publish')"
check "a caller with a map of secrets is a secret held" "1" "$(audit "$(plant callermap 'jobs:
  j:
    uses: ./.github/workflows/x.yml
    secrets:
      K: literal')" | grep -c 'does not declare environment: publish')"
check "an empty map of secrets holds none" "" "$(audit "$(plant callerempty 'jobs:
  j:
    uses: ./.github/workflows/x.yml
    secrets: {}')")"
check "the token of the run is not a secret held" "" "$(audit "$(form '${{ secrets.GITHUB_TOKEN }}')")"
check "the words secrets.X in a string, which is no reference, are not a secret held" "" "$(audit "$(form "\${{ format('{0}', 'secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY') }}")")"
check "the token with a string that holds }} before it is still no secret" "" "$(audit "$(form "\${{ format('}}', secrets.GITHUB_TOKEN) }}")")"

echo "-- every scalar is read as written, the keys too, and what cannot be read fails"
DECL='does not declare environment: publish'
check "an env variable that is called if, with a secret in it, is a secret held" "1" "$(audit "$(plant envif 'jobs:
  j:
    runs-on: x
    steps:
      - run: echo
        env:
          if: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}')" | grep -c "$DECL")"
check "and so is an entry of with called if" "1" "$(audit "$(plant withif 'jobs:
  j:
    runs-on: x
    steps:
      - uses: actions/checkout@v4
        with:
          if: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}')" | grep -c "$DECL")"
check "and so is a secret in a key of a map" "1" "$(audit "$(plant key 'jobs:
  j:
    runs-on: x
    steps:
      - run: echo
        env:
          ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}: a')" | grep -c "$DECL")"
check "and so is a secret named in the job's own if, with no braces" "1" "$(audit "$(plant jobif 'jobs:
  j:
    runs-on: x
    if: secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY != '"''"'
    steps:
      - run: echo')" | grep -c "$DECL")"
check "a collection with a tag is a workflow that cannot be read, and fails" "1" "$(audit "$(plant tagged 'jobs:
  j:
    runs-on: x
    steps: !!set {a, b}')" | grep -c 'cannot be read as a workflow')"
check "a tag of its own is a workflow that cannot be read, and fails" "1" "$(audit "$(plant tagged2 'jobs:
  j:
    runs-on: x
    steps: !secret [a]')" | grep -c 'cannot be read as a workflow')"
check "a workflow that is not YAML fails" "1" "$(audit "$(plant notyaml 'jobs: [')" | grep -c 'cannot be read as a workflow')"
check "a job that is not a map fails" "1" "$(audit "$(plant notmap 'jobs:
  j: just text')" | grep -c 'is not a map')"

echo "-- a job is found by the key it is built with, whatever it is called"
for jobname in yes on 'no' null '~' 1 1.0 'true' 'y' 'off'; do
	check "a job called $jobname that reads a secret with no guard is reported" "1" "$(audit "$(plant "jn$RANDOM" "jobs:
  $jobname:
    runs-on: x
    steps:
      - run: echo
        env:
          K: \${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}")" | grep -c 'reads a secret and does not declare environment: publish')"
done
check "two jobs that are the same key once built (yes and on) are a workflow that cannot be read, and fail" "1" "$(audit "$(plant collide 'jobs:
  yes:
    runs-on: x
    steps: [{run: echo}]
  on:
    runs-on: x
    steps:
      - run: echo
        env:
          K: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}')" | grep -c 'cannot be read as a workflow')"
check "a job written twice is a workflow that cannot be read, and fails" "1" "$(audit "$(plant twice 'jobs:
  j:
    runs-on: x
    steps:
      - run: echo
        env:
          K: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}
  j:
    runs-on: x
    steps: [{run: echo}]')" | grep -c 'cannot be read as a workflow')"
check "a merge key among the jobs is flattened the same on both sides, and what it makes of the document fails (a secret outside any job, jobs that are not maps)" "3" "$(audit "$(plant merge 'x-base: &base
  runs-on: x
  steps:
    - run: echo
      env:
        K: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}
jobs:
  <<: *base
  j:
    runs-on: x
    steps: [{run: echo}]')" | grep -c -e 'is not a map' -e 'named outside any job')"
check "jobs that is null is a workflow with no job, which is no secret held" "" "$(audit "$(plant nulljobs 'jobs:')")"

finish
