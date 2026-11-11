#!/usr/bin/env bash
# Derives the context every step needs from the two mandatory inputs.
# Env: PROJECT, ENVIRONMENT. Output (GITHUB_OUTPUT when set, stdout otherwise): stage (Dev|Stg|Prod).
# --print: the bare stage on stdout ALWAYS (for `stage="$(derive-context.sh --print)"`). Without it the output goes to
# GITHUB_OUTPUT inside Actions, so capturing stdout there yields an empty stage.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env PROJECT ENVIRONMENT
stage="$(stage_of "$ENVIRONMENT")" || die "environment must be dev, stg or prod (got '$ENVIRONMENT')"
if [[ ${1:-} == --print ]]; then
  printf '%s\n' "$stage"
  exit 0
fi
printf 'stage=%s\n' "$stage" >>"${GITHUB_OUTPUT:-/dev/stdout}"
