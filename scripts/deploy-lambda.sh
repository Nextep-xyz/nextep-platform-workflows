#!/usr/bin/env bash
# Lambda deploy (P-CI-11, P-CI-12): build-command, then hotswap (only in HOTSWAP_ENVIRONMENTS) or the full deploy.
# The runtime variables (SSM + secrets) live ONLY in the environment of the deploy command.
# Env: PROJECT ENVIRONMENT AWS_REGION BUILD_COMMAND DEPLOY_COMMAND HOTSWAP_COMMAND HOTSWAP_ENVIRONMENTS
#      DEPLOY_ENV_SSM DEPLOY_ENV_SECRETS (+ contract variables APP_ENV APP_STAGE STACK_SUFFIX, inherited)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=fetch-deploy-env.sh
source "$here/fetch-deploy-env.sh"
require_env PROJECT ENVIRONMENT AWS_REGION DEPLOY_COMMAND

stage="$(stage_of "$ENVIRONMENT")" || die "environment must be dev, stg or prod"
export TPL_PROJECT="$PROJECT" TPL_ENV="$ENVIRONMENT" TPL_STAGE="$stage" TPL_REGION="$AWS_REGION"

CMD="${BUILD_COMMAND:-}" "$here/run-command.sh" build

cmd="$DEPLOY_COMMAND"
label="deploy"
if [[ -n ${HOTSWAP_COMMAND:-} ]] && [[ ",${HOTSWAP_ENVIRONMENTS:-dev}," == *",$ENVIRONMENT,"* ]]; then
  cmd="$HOTSWAP_COMMAND"
  label="hotswap deploy"
fi

load_deploy_env
(
  unset DEPLOY_ENV_SSM DEPLOY_ENV_SECRETS BUILD_COMMAND DEPLOY_COMMAND HOTSWAP_COMMAND HOTSWAP_ENVIRONMENTS TPL_PROJECT TPL_ENV TPL_STAGE TPL_REGION
  if ((${#DEPLOY_ENV_ASSIGN[@]} > 0)); then export "${DEPLOY_ENV_ASSIGN[@]}"; fi
  CMD="$cmd" exec "$here/run-command.sh" "$label"
)
