#!/usr/bin/env bash
# Runs a project command (input of the workflow) with `bash -c`. The command arrives in $CMD (never interpolated
# into a run: block). An empty command is skipped. $CMD itself is removed from the command's environment.
#   CMD="pnpm run lint" run-command.sh <label>
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

label="${1:?usage: run-command.sh <label>}"
cmd="${CMD-}"
if [[ -z $cmd ]]; then
  log "skipped '$label': no command configured"
  exit 0
fi
rc=0
echo "::group::${label}"
(
  unset CMD
  exec bash -c "$cmd"
) || rc=$?
echo "::endgroup::"
((rc == 0)) || die "'$label' failed (exit $rc)"
