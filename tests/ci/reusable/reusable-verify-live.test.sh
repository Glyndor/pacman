#!/usr/bin/env bash
#
# Behaviour tests for .github/workflows/reusable-verify-live.yml, the read-only check of the published repository that
# publish.yml calls after a publication and verify-live.yml calls on a schedule. It holds no secret, has no write
# permission, takes one input (which image of Arch the host is made from), runs only scripts that exist in the repository, and the
# image it passes is one run-live.sh knows. A job that grew a secret or a permission would be a read of the public
# address turned into something that can write, which is what these cases look for.
#
# Requires: python3 with PyYAML, or the workflow-files helper of the CI fixtures.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck disable=SC1091 # the shared fixtures
. "$HERE/tests/fixtures/pacman/lib.sh"
WORKFLOW="$HERE/.github/workflows/reusable-verify-live.yml"

facts() { python3 -I - "$WORKFLOW" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
what = sys.argv[2]
if what == "secrets":
	print(len(re.findall(r"secrets\.|secrets:", text)))
elif what == "permissions-write":
	print(len(re.findall(r"^\s*[a-z-]+: write\s*$", text, re.M)))
elif what == "top-permissions":
	print(1 if re.search(r"^permissions: \{\}\s*$", text, re.M) else 0)
elif what == "workflow-call":
	print(1 if re.search(r"^on:\n  workflow_call:", text, re.M) else 0)
elif what == "other-triggers":
	print(len(re.findall(r"^  (push|pull_request|pull_request_target|schedule|workflow_dispatch):", text, re.M)))
elif what == "jobs":
	print(len(re.findall(r"^  [a-z-]+:\n    name: ", text, re.M)))
elif what == "timeouts":
	print(len(re.findall(r"^    timeout-minutes: [0-9]+$", text, re.M)))
elif what == "unpinned-actions":
	print(len([m for m in re.findall(r"uses: (\S+)", text) if not re.match(r"[\w./-]+@[0-9a-f]{40}$", m)]))
elif what == "third-party-actions":
	print(len([m for m in re.findall(r"uses: ([^/@\s]+)/", text) if m not in ("actions", "github")]))
elif what == "persist-credentials":
	print(len(re.findall(r"persist-credentials: false", text)), len(re.findall(r"uses: actions/checkout@", text)))
elif what == "scripts":
	print(" ".join(sorted(set(re.findall(r"scripts/[a-z-]+/[a-z-]+\.(?:sh|py)", text)))))
elif what == "default-image":
	m = re.search(r"image:\n\s+type: string\n\s+default: (\w+)", text)
	print(m.group(1) if m else "")
PY
}

check "it is called by another workflow and by nothing else" "1 0" "$(facts workflow-call) $(facts other-triggers)"
check "no permission is granted at the top" "1" "$(facts top-permissions)"
check "no job asks for a write permission" "0" "$(facts permissions-write)"
check "no secret is named anywhere in it" "0" "$(facts secrets)"
check "every job has a timeout" "$(facts jobs)" "$(facts timeouts)"
check "there are jobs" "yes" "$([ "$(facts jobs)" -ge 2 ] && echo yes || echo no)"
check "every action is pinned to a commit" "0" "$(facts unpinned-actions)"
check "and only the actions of actions/ and github/ are used" "0" "$(facts third-party-actions)"
check "every checkout keeps no credentials" "$(facts persist-credentials | cut -d' ' -f2) $(facts persist-credentials | cut -d' ' -f2)" "$(facts persist-credentials)"
check "the image defaults to the pinned one" "pinned" "$(facts default-image)"
missing=""
for script in $(facts scripts); do [ -f "$HERE/$script" ] || missing="$missing $script"; done
check "every script it runs is in the repository" "" "$missing"
check "run-live.sh knows the image that is the default here" "1" "$(grep -c -E '^\s+pinned\) image=' "$HERE/scripts/verify/run-live.sh" || true)"

finish
