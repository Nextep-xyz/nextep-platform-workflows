#!/usr/bin/env bash
# Library: SOURCE it, then `load_deploy_env`. Reads DEPLOY_ENV_SSM ({"VAR":"<ssm param template>"}) and
# DEPLOY_ENV_SECRETS ({"VAR":"<secret id template>#<json key>"}), MASKS every value before anything else, and fills
# the array DEPLOY_ENV_ASSIGN with "VAR=value". Nothing is exported, printed or written to the runner env file:
# the caller exports the array inside the subshell that runs the deploy command.
# Needs TPL_PROJECT TPL_ENV TPL_STAGE TPL_REGION and AWS_REGION.
# shellcheck shell=bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DEPLOY_ENV_ASSIGN=()
_FDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FDE_DENY='^(PATH|HOME|SHELL|IFS|BASH_ENV|ENV|SHELLOPTS|PS4|LD_.*|NODE_OPTIONS|NODE_TLS_.*|DATABASE_URL|GITHUB_.*|RUNNER_.*|AWS_.*|PROJECT|APP_ENV|APP_STAGE|STACK_SUFFIX|IMAGE_TAG)$'

_fde_check_name() {
  [[ $1 =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "deploy env: '$1' is not a valid variable name (UPPER_SNAKE_CASE)"
  [[ ! $1 =~ $_FDE_DENY ]] || die "deploy env: '$1' is a reserved variable name"
}

load_deploy_env() {
  local ssm_map="${DEPLOY_ENV_SSM:-}" secret_map="${DEPLOY_ENV_SECRETS:-}"
  [[ -n $ssm_map ]] || ssm_map='{}'
  [[ -n $secret_map ]] || secret_map='{}'
  local name tpl resolved value id key raw
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    _fde_check_name "$name"
    tpl="$(jq -r --arg n "$name" '.[$n]' <<<"$ssm_map")"
    resolved="$("$_FDE_DIR/resolve-template.sh" deploy-env-ssm "$tpl")"
    value="$(aws ssm get-parameter --region "$AWS_REGION" --name "$resolved" --with-decryption --query 'Parameter.Value' --output text)" ||
      die "deploy env: could not read SSM parameter '$resolved' for $name"
    mask "$value"
    DEPLOY_ENV_ASSIGN+=("$name=$value")
  done < <(jq -r 'keys[]' <<<"$ssm_map")

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    _fde_check_name "$name"
    tpl="$(jq -r --arg n "$name" '.[$n]' <<<"$secret_map")"
    [[ $tpl == *'#'* ]] || die "deploy env: '$name' must be '<secret id>#<json key>'"
    id="$("$_FDE_DIR/resolve-template.sh" deploy-env-secrets "${tpl%%#*}")"
    key="${tpl#*#}"
    raw="$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$id" --query SecretString --output text)" ||
      die "deploy env: could not read secret '$id' for $name"
    value="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$raw")"
    raw=""
    [[ -n $value ]] || die "deploy env: key '$key' not found in secret '$id' (for $name)"
    mask "$value"
    DEPLOY_ENV_ASSIGN+=("$name=$value")
  done < <(jq -r 'keys[]' <<<"$secret_map")
}
