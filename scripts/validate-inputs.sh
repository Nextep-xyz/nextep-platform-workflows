#!/usr/bin/env bash
# Validates the inputs of a lego-aws-* workflow BEFORE anything runs. Reports every problem, not only the first.
#   validate-inputs.sh <cicd|environment-deploy>
# Inputs arrive as INPUT_<NAME> (dashes -> underscores). Also: EVENT_NAME (github.event_name, G26) and
# REF_NAME (github.ref_name, G21), both passed through env: by the caller.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

# The composite hands every workflow input as one JSON object (INPUTS_JSON); expose them as INPUT_<NAME>.
if [[ -n ${INPUTS_JSON:-} ]]; then
  while IFS= read -r key; do
    name="${key^^}"
    printf -v "INPUT_${name//-/_}" '%s' "$(jq -r --arg k "$key" '.[$k] | tostring' <<<"$INPUTS_JSON")"
    export "INPUT_${name//-/_}"
  done < <(jq -r 'keys[]' <<<"$INPUTS_JSON")
fi

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
case "$compute" in lambda | ecs | static) ;; *) err "input 'compute' must be lambda, ecs or static (got '$compute')" ;; esac
case "$(val package-manager)" in npm | pnpm) ;; *) err "input 'package-manager' must be npm or pnpm (got '$(val package-manager)')" ;; esac
case "$(val db-ssl-mode)" in verify-full | require) ;; *) err "input 'db-ssl-mode' must be verify-full or require, never anything weaker (got '$(val db-ssl-mode)')" ;; esac
[[ "$(val db-port)" =~ ^[0-9]{1,5}$ ]] || err "input 'db-port' must be a port number (got '$(val db-port)')"
[[ "$(val migration-timeout-minutes)" =~ ^[0-9]{1,3}$ ]] || err "input 'migration-timeout-minutes' must be a number of minutes (got '$(val migration-timeout-minutes)')"
case "$run_deploy" in true | false) ;; *) err "input 'run-deploy' must be true or false (got '$run_deploy')" ;; esac
if [[ -n "$(val node-version)" && -n "$(val node-version-file)" ]]; then
  err "inputs 'node-version' and 'node-version-file' are mutually exclusive"
fi

# --- P2 inputs: db-access (GH3), install-dirs, test-database-image (GH4), hotswap in prod (GH9) ---------------------
db_access="$(val db-access)"
[[ -n $db_access ]] || db_access=ssm-tunnel
case "$db_access" in ssm-tunnel | iam-direct) ;; *) err "input 'db-access' must be ssm-tunnel or iam-direct (got '$db_access')" ;; esac

install_dirs="$(val install-dirs)"
if [[ -n $install_dirs ]]; then
  IFS=',' read -r -a _dirs <<<"$install_dirs"
  for d in "${_dirs[@]}"; do
    if [[ $d != . && ! $d =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || [[ $d == *..* ]] || [[ $d == */ ]]; then
      err "input 'install-dirs' has an invalid directory '$d' (comma separated relative paths, no '..', no spaces, no trailing '/')"
    fi
  done
fi

test_image="$(val test-database-image)"
if [[ -n $test_image ]]; then
  if [[ $test_image =~ ^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]]; then
    :
  elif [[ $test_image =~ ^[a-z0-9][a-z0-9._/-]*:([A-Za-z0-9._-]+)$ ]]; then
    [[ ${BASH_REMATCH[1]} != latest ]] || err "input 'test-database-image' must not use the tag 'latest' (got '$test_image')"
  else
    err "input 'test-database-image' must be an image with a fixed tag or a digest, for example postgres:17 (got '$test_image')"
  fi
fi

if [[ $flow == cicd ]]; then
  IFS=',' read -r -a _hs <<<"$(val hotswap-environments)"
  for e in "${_hs[@]}"; do
    [[ $e != prod ]] || err "input 'hotswap-environments' must not include prod: hotswap leaves drift in CloudFormation and is never allowed in production"
  done
fi
if [[ $flow == environment-deploy ]]; then
  case "$(val migrate-before-deploy)" in true | false | "") ;; *) err "input 'migrate-before-deploy' must be true or false (got '$(val migrate-before-deploy)')" ;; esac
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
  [[ -z "$(val image-tag)" && $compute != static ]] && migrates=true
  [[ $compute == ecs ]] && need ecr-repository "when compute=ecs"
else
  if [[ $run_deploy == true ]]; then
    if [[ $compute == lambda || $compute == static ]]; then
      need deploy-command "when compute=lambda or compute=static"
    elif [[ $compute == ecs ]]; then
      need ecs-cluster-ssm-param "when compute=ecs"
      need ecs-service-ssm-param "when compute=ecs"
      need ecr-repository "when compute=ecs"
    fi
  fi
  [[ -n "$(val bastion-id-ssm-param)" ]] && migrates=true
  [[ $db_access == iam-direct && -n "$(val db-endpoint-ssm-param)" ]] && migrates=true
  [[ "$(val ecs-deploy-mode)" == force-new-deployment ]] || err "input 'ecs-deploy-mode' only supports force-new-deployment in P1 (got '$(val ecs-deploy-mode)')"
fi
if [[ $flow == environment-deploy && $migrates == true ]] || [[ $flow == cicd && $migrates == true ]]; then
  if [[ $db_access == iam-direct ]]; then
    need db-endpoint-ssm-param "when db-access=iam-direct (the endpoint is the only thing the migration needs)"
  else
    need bastion-id-ssm-param "to migrate"
    need db-endpoint-ssm-param "to migrate"
    need db-secret-id "to migrate"
    need db-name "to migrate"
  fi
fi

# --- compute=static: no database stage ---------------------------------------------------------------------------------
# A static site has no database. The migration inputs are rejected when set, so a caller never carries dead configuration
# that looks like it does something. Inputs whose default is empty must stay empty; the two migration commands may only
# keep their contract default (a caller that sets the same value as the default is indistinguishable and harmless).
if [[ $compute == static ]]; then
  for n in bastion-id-ssm-param db-endpoint-ssm-param db-secret-id db-name db-schema migration-pre-command post-migrate-command; do
    [[ -z "$(val "$n")" ]] || err "input '$n' is not allowed with compute=static (a static site has no database stage)"
  done
  [[ "$db_access" != iam-direct ]] || err "input 'db-access' is not allowed with compute=static (a static site has no database stage)"
  [[ "$(val migrate-before-deploy)" != true ]] || err "input 'migrate-before-deploy' is not allowed with compute=static (a static site has no database stage)"
  for pair in 'migration-command:make migrate' 'migration-verify-command:make migrate-status'; do
    n="${pair%%:*}"
    d="${pair#*:}"
    [[ -z "$(val "$n")" || "$(val "$n")" == "$d" ]] || err "input '$n' is not allowed with compute=static (a static site has no database stage)"
  done
fi

# --- image-tag (rollback) --------------------------------------------------------------------------------------------
image_tag="$(val image-tag)"
if [[ -n $image_tag ]]; then
  [[ $image_tag =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || err "input 'image-tag' is not a valid image tag (got '$image_tag')"
  [[ $compute == ecs ]] || err "input 'image-tag' (rollback) only applies when compute=ecs"
fi

# --- G19: the OIDC role stack is never deployed from a run -----------------------------------------------------------
guarded_inputs=(post-deploy-command)
[[ $flow == environment-deploy ]] && guarded_inputs+=(infra-deploy-command infra-bootstrap-command)
while IFS= read -r stack; do
  [[ -n $stack ]] || continue
  for cmd_input in "${guarded_inputs[@]}"; do
    if grep -Eiq "(^|[^A-Za-z0-9])${stack}([^A-Za-z0-9]|\$)" <<<"$(val "$cmd_input")"; then
      err "input '$cmd_input' targets the OIDC role stack '$stack': it must never be deployed from a run"
    fi
  done
done <"$here/lib/oidc-stack-names"
# Prefixed names (for example <Project>GithubOidc) have no word boundary: match them as case-insensitive substrings.
while IFS= read -r frag; do
  [[ -n $frag ]] || continue
  for cmd_input in "${guarded_inputs[@]}"; do
    if grep -Fiq -- "$frag" <<<"$(val "$cmd_input")"; then
      err "input '$cmd_input' mentions '$frag', the name of an OIDC role stack: it must never be deployed from a run (to exclude it from a listing, filter on 'oidc')"
    fi
  done
done <"$here/lib/oidc-stack-substrings"

# --- commands: {placeholders} are NOT expanded there ------------------------------------------------------------------
# Only the template inputs (*-ssm-param, db-secret-id, ecr-repository, ...) expand {stage}, {env}, {project}, {region}.
# A command receives the same values as environment variables; a literal '{stage}' would reach the tool as is (a stack
# called 'Api-{stage}' that does not exist), so it fails here, naming the input and the variable to use. Discovered by
# name (every INPUT_*_COMMAND), not from a list: a command input added later is covered without touching this file.
while IFS= read -r var; do
  [[ -n $var ]] || continue
  cmd_name="${var#INPUT_}"
  cmd_name="${cmd_name%_COMMAND}"
  cmd_name="$(tr '[:upper:]_' '[:lower:]-' <<<"$cmd_name")-command"
  for pair in stage:APP_STAGE env:APP_ENV project:PROJECT region:AWS_REGION; do
    placeholder="${pair%%:*}"
    envvar="${pair#*:}"
    if [[ ${!var} =~ (^|[^$])\{${placeholder}\} ]]; then
      err "input '$cmd_name' uses '{$placeholder}', which is not expanded in commands (only in template inputs): use \$$envvar"
    fi
  done
done < <(compgen -A variable INPUT_ | grep '_COMMAND$' || true)

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

# --- telemetry (SPEC telemetria-dora): both inputs are optional; when set they must be valid (T2, T12) ----------------------
# The audience is a plain slug so this job cannot be used to mint a token for a cloud provider; the URL is https without
# credentials. The telemetry composite checks both again: its job runs even when this gate fails.
# shellcheck source=lib/telemetry.sh
source "$here/lib/telemetry.sh"
t_url="$(val telemetry-url)"
t_aud="$(val telemetry-audience)"
if [[ -n $t_url ]] && ! telemetry_valid_url "$t_url"; then
  err "input 'telemetry-url' must be an https URL (host, optional port and path) without credentials, query or spaces"
fi
if [[ -n $t_aud ]] && ! telemetry_valid_audience "$t_aud"; then
  err "input 'telemetry-audience' must be a plain lower-case slug ([a-z0-9-], 3 to 63 characters, no dots, colons or slashes)"
fi
if [[ -n $t_url && -z $t_aud ]]; then warn "telemetry-url is set but telemetry-audience is empty: telemetry stays off"; fi
if [[ -z $t_url && -n $t_aud ]]; then warn "telemetry-audience is set but telemetry-url is empty: telemetry stays off"; fi

# --- verdict ---------------------------------------------------------------------------------------------------------
if ((${#errs[@]} > 0)); then
  for e in "${errs[@]}"; do printf '::error title=Invalid inputs::%s\n' "$e" >&2; done
  exit 1
fi
log "inputs OK (flow=$flow project=$project environment=$environment compute=$compute)"
