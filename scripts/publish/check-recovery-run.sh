#!/usr/bin/env bash
#
# Refuse to recover from a run that is not a finished publication of this repository, from main.
#
#   check-recovery-run.sh <run id>
#
# Env: REPO (owner/name) and GH_TOKEN with actions: read. What the artifacts of the run hold is verified by signature
# afterwards; this keeps a run of another workflow, another branch or another repository from being named at all.
set -euo pipefail
export LC_ALL=C

id="${1:-}"
[[ "$id" =~ ^[1-9][0-9]{0,19}$ ]] || { echo "::error::'$id' is not a run id" >&2; exit 2; }
[ -n "${REPO:-}" ] || { echo "::error::REPO is not set" >&2; exit 2; }
run="$(gh api "repos/$REPO/actions/runs/$id" --jq '[.path, .head_branch, .event, .head_repository.full_name, .status] | @tsv')" \
	|| { echo "::error::cannot read run $id of $REPO" >&2; exit 1; }
IFS=$'\t' read -r path branch event head status <<< "$run"
[ "$path" = .github/workflows/publish.yml ] || { echo "::error::run $id is not a publication: its workflow is $path" >&2; exit 1; }
[ "$branch" = main ] && [ "$head" = "$REPO" ] || { echo "::error::run $id did not run on main of $REPO: it ran on $branch of $head" >&2; exit 1; }
case "$event" in schedule | workflow_dispatch) ;; *) echo "::error::run $id was started by $event, which a publication is not" >&2; exit 1 ;; esac
[ "$status" = completed ] || { echo "::error::run $id is $status; a publication that is still running is not recovered from" >&2; exit 1; }
echo "run $id is a finished publication from main"
