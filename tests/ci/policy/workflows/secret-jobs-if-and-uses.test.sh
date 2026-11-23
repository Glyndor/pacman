#!/usr/bin/env bash
#
# The rule of secret-jobs-are-guarded.test.sh, over the `if` of a job that holds a secret and of its steps after the guard (none is
# carried, whatever it says) and over the actions it may use (a closed list pinned by commit, none with a pre hook, or a local one).
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the text of workflows, with ${{ }} meant literally
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/ci/secret-plants.sh"

echo "-- a step after the guard that runs when the guard fails, and what the steps inherit"
IFMSG="which a step after the guard may not carry"
# An `if` is not analysed: whatever it says, a step after the guard carries none (the list of exact texts that are allowed is empty).
for cond in 'always()' 'Always()' 'failure()' 'cancelled()' 'success()' '!success()' 'success() || true' 'success() == false' '${{ !success() }}' '${{ always() }}' 'x ${{ always() }}' "github.ref == 'always()'" 'true' 'false'; do
	check "a step with if: $cond after the guard is reported" "1" "$(audit "$(plant "st$RANDOM" "$(job "$ENV" "$GUARD" "      - if: \"${cond//\"/\\\"}\"
        run: echo")")" | grep -c "$IFMSG")"
done
check "a step with an if that is not a string is reported" "1" "$(audit "$(plant stbool "$(job "$ENV" "$GUARD" '      - if: false
        run: echo')")" | grep -c "$IFMSG")"
check "an if on the job itself is reported" "1" "$(audit "$(plant jobif2 "$(job '    environment: publish
    if: github.ref == '"'refs/heads/main'"'
' "$GUARD" '')")" | grep -c 'has an if (.*), which no job that holds a secret may carry')"
check "a step with no if is not" "" "$(audit "$(plant noif "$(job "$ENV" "$GUARD" '      - run: echo')")")"

echo "-- the actions of a job that holds a secret are a closed list, exactly as pinned"
USESMSG="which is not on the closed list of actions with no pre hook"
for u in actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 ./.github/actions/local; do
	check "the step that uses $u is accepted" "" "$(audit "$(plant "ua$RANDOM" "$(job "$ENV" "$GUARD" "      - uses: $u")")")"
done
for u in actions/cache@3d3c42e5aac5ba805825da76410c181273ba90b1 actions/checkout@0000000000000000000000000000000000000000 actions/checkout@v4 actions/checkout \
	docker://alpine:3 docker://ghcr.io/x/y@sha256:0000000000000000000000000000000000000000000000000000000000000000 someone/else@3d3c42e5aac5ba805825da76410c181273ba90b1 \
	./../outside .github/actions/x; do
	check "the step that uses $u is reported" "1" "$(audit "$(plant "ub$RANDOM" "$(job "$ENV" "$GUARD" "      - uses: $u")")" | grep -c "$USESMSG")"
done

finish
