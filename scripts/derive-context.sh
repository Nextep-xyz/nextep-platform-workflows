#!/usr/bin/env bash
# Derives the context every step needs from the two mandatory inputs.
# Env: PROJECT, ENVIRONMENT. Output: ALWAYS stdout, `stage=<Dev|Stg|Prod>`. Callers either capture it with $(...) or append it with
# `>>"$GITHUB_OUTPUT"`. It must never write to GITHUB_OUTPUT itself: inside a step that variable is always set, so a captured call
# would get nothing (gate: no-output-capture).
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env PROJECT ENVIRONMENT
stage="$(stage_of "$ENVIRONMENT")" || die "environment must be dev, stg or prod (got '$ENVIRONMENT')"
printf 'stage=%s\n' "$stage"
