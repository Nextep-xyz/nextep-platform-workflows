#!/usr/bin/env bash
# Resolves the bastion id and the database endpoint from SSM and checks that the bastion is Online.
# The bastion of dev/stg is switched off outside its window: fail FAST with a message that says so (no waiting).
# Env: AWS_REGION, BASTION_ID_PARAM, DB_ENDPOINT_PARAM (already-resolved SSM parameter names).
# Output (GITHUB_OUTPUT when set, stdout otherwise): bastion-id, db-endpoint.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_env AWS_REGION BASTION_ID_PARAM DB_ENDPOINT_PARAM

bastion_id="$(aws ssm get-parameter --region "$AWS_REGION" --name "$BASTION_ID_PARAM" --query 'Parameter.Value' --output text)" ||
  die "could not read the bastion id from SSM parameter '$BASTION_ID_PARAM'"
[[ -n $bastion_id && $bastion_id != None ]] || die "SSM parameter '$BASTION_ID_PARAM' is empty"

ping="$(aws ssm describe-instance-information --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$bastion_id" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
if [[ $ping != Online ]]; then
  die "bastion $bastion_id is not Online (PingStatus='${ping:-unknown}'): it is switched off or outside its window (dev/stg bastions are stopped off-hours). Start it or retry inside the window; this job does not wait."
fi

db_endpoint="$(aws ssm get-parameter --region "$AWS_REGION" --name "$DB_ENDPOINT_PARAM" --query 'Parameter.Value' --output text)" ||
  die "could not read the database endpoint from SSM parameter '$DB_ENDPOINT_PARAM'"
[[ -n $db_endpoint && $db_endpoint != None ]] || die "SSM parameter '$DB_ENDPOINT_PARAM' is empty"

log "bastion $bastion_id is Online"
{
  printf 'bastion-id=%s\n' "$bastion_id"
  printf 'db-endpoint=%s\n' "$db_endpoint"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
