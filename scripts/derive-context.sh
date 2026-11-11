#!/usr/bin/env bash
# Derives the context every step needs from the two mandatory inputs.
# Env: PROJECT, ENVIRONMENT. Output (GITHUB_OUTPUT when set, stdout otherwise): stage (Dev|Stg|Prod).
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env PROJECT ENVIRONMENT
stage="$(stage_of "$ENVIRONMENT")" || die "environment must be dev, stg or prod (got '$ENVIRONMENT')"
printf 'stage=%s\n' "$stage" >>"${GITHUB_OUTPUT:-/dev/stdout}"
