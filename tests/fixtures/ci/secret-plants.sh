# shellcheck shell=bash
# Shared by the suites secret-jobs-*.test.sh: a scratch folder, the counters, the audit (secret-audit.py) and the helpers that plant
# a workflow. Sourced, never run; it is not a suite. HERE is the root of the repository and is set by the suite.
# shellcheck disable=SC2016,SC2034 # the text of workflows, with ${{ }} meant literally; the names are used by the suites that source this

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
finish() {
	echo "$pass passed, $fail failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[1]##*/}" "$pass" "$fail"
	[ "$fail" -eq 0 ]
}
audit() { # $1=workflows dir: one line per offence
	python3 -I "$HERE/tests/fixtures/ci/secret-audit.py" "$1"
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
          case "$EVENT" in schedule | workflow_dispatch) ;; *) echo "::error::$EVENT is not an event this workflow runs on"; exit 1 ;; esac
          [ "$REF" = refs/heads/main ] || { echo "::error::$REF is not refs/heads/main"; exit 1; }'
job() { # <environment line> <guard> <extra step>
	printf 'jobs:\n  j:\n    runs-on: x\n%s    steps:\n%s\n      - run: echo\n        env:\n          K: ${{ secrets.GLYNDOR_PACMAN_GPG_PRIVATE_KEY }}\n%s\n' "$1" "$2" "$3"
}
ENV='    environment: publish
'
