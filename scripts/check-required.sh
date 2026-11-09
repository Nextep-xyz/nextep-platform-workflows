#!/usr/bin/env bash
# P-CI-07: the runtime configuration exists. Lists EVERYTHING that is missing, not only the first.
# Env: AWS_REGION, REQUIRED_SSM_PARAMS / REQUIRED_SECRETS (JSON arrays of templates), PROJECT, ENVIRONMENT.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
require_env AWS_REGION PROJECT ENVIRONMENT

stage="$(stage_of "$ENVIRONMENT")" || die "environment must be dev, stg or prod"
export TPL_PROJECT="$PROJECT" TPL_ENV="$ENVIRONMENT" TPL_STAGE="$stage" TPL_REGION="$AWS_REGION"

missing=()
while IFS= read -r tpl; do
  [[ -n $tpl ]] || continue
  name="$("$here/resolve-template.sh" required-ssm-params "$tpl")"
  aws ssm get-parameter --region "$AWS_REGION" --name "$name" --query 'Parameter.Name' --output text >/dev/null 2>&1 ||
    missing+=("SSM parameter $name")
done < <(jq -r '.[]?' <<<"${REQUIRED_SSM_PARAMS:-[]}")
while IFS= read -r tpl; do
  [[ -n $tpl ]] || continue
  name="$("$here/resolve-template.sh" required-secrets "$tpl")"
  aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$name" --query 'Name' --output text >/dev/null 2>&1 ||
    missing+=("secret $name")
done < <(jq -r '.[]?' <<<"${REQUIRED_SECRETS:-[]}")

if ((${#missing[@]} > 0)); then
  for m in "${missing[@]}"; do printf '::error title=Missing runtime configuration::%s\n' "$m" >&2; done
  die "${#missing[@]} required runtime item(s) are missing: $(printf '%s; ' "${missing[@]}")"
fi
log "all required runtime configuration exists"
