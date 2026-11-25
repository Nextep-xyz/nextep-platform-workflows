#!/usr/bin/env bash
# Runs a project command (input of the workflow) with `bash -c`. The command arrives in $CMD (never interpolated
# into a run: block). An empty command is skipped. $CMD itself is removed from the command's environment.
#   CMD="pnpm run lint" run-command.sh <label>
# NEXTEP_GUARDRAILS_MODE (enforce | warn) is set for EVERY command that goes through here, from APP_ENV and through the single function of
# lib/enforcement.sh: it is how @nextep/cdk-guardrails (the plugin inside `cdk deploy`, the Jest helper inside the test command) learns whether
# the environment blocks or only warns. It overrides whatever the environment already had, and an empty or unknown APP_ENV means enforce.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/enforcement.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/enforcement.sh"

label="${1:?usage: run-command.sh <label>}"
cmd="${CMD-}"
if [[ -z $cmd ]]; then
  log "skipped '$label': no command configured"
  exit 0
fi
guardrails_mode="$(enforcement_mode "${APP_ENV-}")"
rc=0
echo "::group::${label}"
(
  unset CMD
  export NEXTEP_GUARDRAILS_MODE="$guardrails_mode"
  exec bash -c "$cmd"
) || rc=$?
echo "::endgroup::"
((rc == 0)) || die "'$label' failed (exit $rc)"
