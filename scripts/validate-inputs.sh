#!/usr/bin/env bash
# Validates the inputs of a lego-aws-* workflow BEFORE anything runs. Reports every problem, not only the first.
#   validate-inputs.sh <cicd|environment-deploy>
# Inputs arrive as INPUT_<NAME> (dashes -> underscores). Also: EVENT_NAME (github.event_name, G26) and
# REF_NAME (github.ref_name, G21), both passed through env: by the caller.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

flow="${1:?usage: validate-inputs.sh <cicd|environment-deploy>}"
[[ $flow == cicd || $flow == environment-deploy ]] || die "validate-inputs: unknown flow '$flow'"

errs=()
err() { errs+=("$*"); }
val() { input_env "$1"; }
need() { [[ -n "$(val "$1")" ]] || err "input '$1' is required $2"; }

project="$(val project)"
environment="$(val environment)"
compute="$(val compute)"
event="${EVENT_NAME:-}"
ref="${REF_NAME:-}"
run_deploy="$(val run-deploy)"
[[ $flow == environment-deploy ]] && run_deploy=true
[[ -n $run_deploy ]] || run_deploy=true

# --- enums and formats ------------------------------------------------------------------------------------------
[[ $project =~ ^[a-z][a-z0-9-]{1,15}$ ]] || err "input 'project' must match ^[a-z][a-z0-9-]{1,15}\$ (got '$project')"
case "$environment" in dev | stg | prod) ;; *) err "input 'environment' must be dev, stg or prod (got '$environment')" ;; esac
case "$compute" in lambda | ecs) ;; *) err "input 'compute' must be lambda or ecs (got '$compute')" ;; esac
case "$(val package-manager)" in npm | pnpm) ;; *) err "input 'package-manager' must be npm or pnpm (got '$(val package-manager)')" ;; esac
case "$(val db-ssl-mode)" in verify-full | require) ;; *) err "input 'db-ssl-mode' must be verify-full or require, never anything weaker (got '$(val db-ssl-mode)')" ;; esac
[[ "$(val db-port)" =~ ^[0-9]{1,5}$ ]] || err "input 'db-port' must be a port number (got '$(val db-port)')"
[[ "$(val migration-timeout-minutes)" =~ ^[0-9]{1,3}$ ]] || err "input 'migration-timeout-minutes' must be a number of minutes (got '$(val migration-timeout-minutes)')"
case "$run_deploy" in true | false) ;; *) err "input 'run-deploy' must be true or false (got '$run_deploy')" ;; esac
if [[ -n "$(val node-version)" && -n "$(val node-version-file)" ]]; then
  err "inputs 'node-version' and 'node-version-file' are mutually exclusive"
fi

# --- G26: the event that triggered the caller must be the allowed one --------------------------------------------
if [[ $flow == environment-deploy ]]; then
  [[ $event == workflow_dispatch ]] || err "environment-deploy only runs on workflow_dispatch (got event '$event')"
else
  case "$event" in push | pull_request | workflow_dispatch) ;; *) err "cicd only runs on push, pull_request or workflow_dispatch (got event '$event')" ;; esac
fi

# --- G21: branch-map guard (mandatory in environment-deploy) ----------------------------------------------------------
branch_map="$(val branch-map)"
if [[ -z $branch_map ]]; then
  [[ $flow == environment-deploy ]] && err "input 'branch-map' is required in environment-deploy (it is the main barrier without GitHub Environments)"
elif ! jq -e 'type == "object" and length > 0 and all(.[]; . == "dev" or . == "stg" or . == "prod")' <<<"$branch_map" >/dev/null 2>&1; then
  err "input 'branch-map' must be a JSON object {\"<branch>\": \"dev|stg|prod\"}"
elif [[ $flow == environment-deploy || ( $run_deploy == true && $event != pull_request ) ]]; then
  mapped="$(jq -r --arg b "$ref" '.[$b] // empty' <<<"$branch_map")"
  if [[ -z $mapped ]]; then
    err "branch '$ref' is not in branch-map: it cannot deploy"
  elif [[ $mapped != "$environment" ]]; then
    err "branch '$ref' maps to '$mapped' in branch-map but environment is '$environment'"
  fi
fi

# --- compute-specific requirements -----------------------------------------------------------------------------------
migrates=false
if [[ $flow == environment-deploy ]]; then
  need infra-deploy-command "in environment-deploy"
  [[ -z "$(val image-tag)" ]] && migrates=true
  [[ $compute == ecs ]] && need ecr-repository "when compute=ecs"
else
  if [[ $run_deploy == true ]]; then
    if [[ $compute == lambda ]]; then
      need deploy-command "when compute=lambda"
    elif [[ $compute == ecs ]]; then
      need ecs-cluster-ssm-param "when compute=ecs"
      need ecs-service-ssm-param "when compute=ecs"
      need ecr-repository "when compute=ecs"
    fi
  fi
  [[ -n "$(val bastion-id-ssm-param)" ]] && migrates=true
  [[ "$(val ecs-deploy-mode)" == force-new-deployment ]] || err "input 'ecs-deploy-mode' only supports force-new-deployment in P1 (got '$(val ecs-deploy-mode)')"
fi
if [[ $flow == environment-deploy && $migrates == true ]] || [[ $flow == cicd && $migrates == true ]]; then
  need bastion-id-ssm-param "to migrate"
  need db-endpoint-ssm-param "to migrate"
  need db-secret-id "to migrate"
  need db-name "to migrate"
fi

# --- image-tag (rollback) --------------------------------------------------------------------------------------------
image_tag="$(val image-tag)"
if [[ -n $image_tag ]]; then
  [[ $image_tag =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || err "input 'image-tag' is not a valid image tag (got '$image_tag')"
  [[ $compute == ecs ]] || err "input 'image-tag' (rollback) only applies when compute=ecs"
fi

# --- G19: the OIDC role stack is never deployed from a run -----------------------------------------------------------
if [[ $flow == environment-deploy ]]; then
  while IFS= read -r stack; do
    [[ -n $stack ]] || continue
    for cmd_input in infra-deploy-command infra-bootstrap-command; do
      if grep -Eiq "(^|[^A-Za-z0-9])${stack}([^A-Za-z0-9]|\$)" <<<"$(val "$cmd_input")"; then
        err "input '$cmd_input' targets the OIDC role stack '$stack': it must never be deployed from a run"
      fi
    done
  done <"$here/lib/oidc-stack-names"
fi

# --- JSON-valued inputs ----------------------------------------------------------------------------------------------
json_input() { # json_input <name> <jq type test> <expected>
  local v
  v="$(val "$1")"
  [[ -z $v ]] && return 0
  jq -e "$2" <<<"$v" >/dev/null 2>&1 || err "input '$1' must be $3"
}
if [[ $flow == cicd ]]; then
  json_input required-ssm-params 'type == "array" and all(.[]; type == "string")' "a JSON array of strings"
  json_input required-secrets 'type == "array" and all(.[]; type == "string")' "a JSON array of strings"
  json_input deploy-env-ssm 'type == "object" and all(.[]; type == "string")' "a JSON object of strings"
  json_input deploy-env-secrets 'type == "object" and all(.[]; type == "string")' "a JSON object of strings"
fi

# --- templates: only known placeholders ------------------------------------------------------------------------------
check_tpl() { # check_tpl <input-name> <template> [--db-url]
  [[ -z ${2:-} ]] && return 0
  local out
  if ! out="$("$here/resolve-template.sh" --check ${3:+"$3"} "$1" "$2" 2>&1)"; then
    err "${out#::error::}"
  fi
}
for n in bastion-id-ssm-param db-endpoint-ssm-param db-secret-id ecs-cluster-ssm-param ecs-service-ssm-param ecr-repository; do
  check_tpl "$n" "$(val "$n")"
done
check_tpl db-url-template "$(val db-url-template)" --db-url
if [[ $flow == cicd ]]; then
  for n in required-ssm-params required-secrets; do
    v="$(val "$n")"
    if [[ -n $v ]] && jq -e 'type == "array"' <<<"$v" >/dev/null 2>&1; then
      while IFS= read -r item; do check_tpl "$n" "$item"; done < <(jq -r '.[]' <<<"$v")
    fi
  done
  for n in deploy-env-ssm deploy-env-secrets; do
    v="$(val "$n")"
    if [[ -n $v ]] && jq -e 'type == "object"' <<<"$v" >/dev/null 2>&1; then
      while IFS= read -r item; do check_tpl "$n" "${item%%#*}"; done < <(jq -r '.[]' <<<"$v")
    fi
  done
fi

# --- verdict ---------------------------------------------------------------------------------------------------------
if ((${#errs[@]} > 0)); then
  for e in "${errs[@]}"; do printf '::error title=Invalid inputs::%s\n' "$e" >&2; done
  exit 1
fi
log "inputs OK (flow=$flow project=$project environment=$environment compute=$compute)"
