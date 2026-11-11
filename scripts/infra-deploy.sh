#!/usr/bin/env bash
# P-EN-08: deploys the infrastructure. The image tag is PINNED (exported as IMAGE_TAG) only in the environments of
# PIN_IMAGE_TAG_ENVIRONMENTS (default stg,prod); elsewhere IMAGE_TAG is not defined for the command.
# The command must never deploy the OIDC role stack: validate-inputs refuses it before anything runs (G19).
# Env: ENVIRONMENT INFRA_DEPLOY_COMMAND [PIN_IMAGE_TAG_ENVIRONMENTS] [DEPLOY_IMAGE_TAG] (+ contract variables, inherited)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
require_env ENVIRONMENT INFRA_DEPLOY_COMMAND

pin_list="${PIN_IMAGE_TAG_ENVIRONMENTS-stg,prod}"
tag="${DEPLOY_IMAGE_TAG:-}"
cmd="$INFRA_DEPLOY_COMMAND"
(
  unset INFRA_DEPLOY_COMMAND PIN_IMAGE_TAG_ENVIRONMENTS DEPLOY_IMAGE_TAG IMAGE_TAG
  if [[ -n $tag && ",$pin_list," == *",$ENVIRONMENT,"* ]]; then
    export IMAGE_TAG="$tag"
    log "image tag pinned for $ENVIRONMENT: $tag"
  else
    log "image tag not pinned in $ENVIRONMENT"
  fi
  CMD="$cmd" exec "$here/run-command.sh" "infra deploy"
)
