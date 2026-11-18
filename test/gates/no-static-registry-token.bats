#!/usr/bin/env bats
# GR15 — the package publishing path has NO static registry token. The CodeArtifact token is minted per run from the OIDC role,
# masked before its first use, handed to exactly one step and only through that step's environment. Subjects are discovered on
# disk: every lego-aws-package-* workflow and contract, every sandbox caller that uses one, every file under .github/ and the
# package scripts. A gate that finds none of them fails.

load 'lib/gates'

TOKEN_NAME_RE='token|secret|passw|credential|npmrc|auth'
# the one place allowed to put the token in an environment, and the only value it may carry
TOKEN_ENV_RE='^(CODEARTIFACT_AUTH_TOKEN|NODE_AUTH_TOKEN|NPM_TOKEN|NPM_CONFIG_.*|.*_AUTH_TOKEN)$'
PUBLISH_COMPOSITE=.github/actions/package-publish/action.yml
# Amendment (v1.5.0, registry login): the install step of setup-project gets the CodeArtifact token of the optional OIDC login, from the
# output of the login step and nowhere else. GL1/GL2 (registry-login.bats) fence that composite; this gate admits exactly that pair.
LOGIN_COMPOSITE=.github/actions/setup-project/action.yml
LOGIN_TOKEN_VALUE='${{ steps.registry.outputs.token }}'

@test "GR15: no package contract, workflow or caller declares or passes a token, a secret or a password" {
  gate_require_tools yq jq
  gate_discover GR15 contracts -maxdepth 1 -type f -name 'lego-aws-package-*.contract.yml'
  local contracts=("${GATE_SUBJECTS[@]}")
  gate_discover_package_workflows GR15
  local workflows=("${GATE_SUBJECTS[@]}")
  gate_discover GR15 test/sandbox/callers -maxdepth 1 -type f -name '*.yml'
  local callers=() f line
  for f in "${GATE_SUBJECTS[@]}"; do
    grep -q 'lego-aws-package-' "$GATES_ROOT/$f" && callers+=("$f")
  done
  ((${#callers[@]} > 0)) || gate_fail "GR15: no sandbox caller of a package workflow was found (a gate that finds nothing proves nothing)"
  GATE_VIOLATIONS=()

  for f in "${contracts[@]}"; do
    gate_json "$f" | jq -e '(.secrets // {}) | length == 0' >/dev/null || gate_violation "$f" "declares secrets: the registry token is minted per run, there is no secret (GR15)"
    while IFS= read -r line; do
      gate_violation "$f" "input '$line' looks like a credential: authentication is the OIDC role, never an input (GR15)"
    done < <(gate_json "$f" | jq -r --arg re "$TOKEN_NAME_RE" '(.inputs // {}) | keys[] | select(test($re; "i"))')
  done
  for f in "${workflows[@]}"; do
    gate_json "$f" | jq -e '(.on.workflow_call.secrets // {}) | length == 0' >/dev/null || gate_violation "$f" "declares workflow_call secrets (GR15)"
    while IFS= read -r line; do
      gate_violation "$f" "input '$line' looks like a credential: authentication is the OIDC role, never an input (GR15)"
    done < <(gate_json "$f" | jq -r --arg re "$TOKEN_NAME_RE" '(.on.workflow_call.inputs // {}) | keys[] | select(test($re; "i"))')
    while IFS= read -r line; do
      gate_violation "$f" "line ${line%%:*} reads the secrets context (GR15)"
    done < <(grep -nE '\$\{\{[^}]*secrets\.' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done
  for f in "${callers[@]}"; do
    gate_json "$f" | jq -e '[.jobs[] | select(.secrets != null)] | length == 0' >/dev/null || gate_violation "$f" "a caller of a package workflow passes secrets (GR15)"
    while IFS= read -r line; do
      gate_violation "$f" "with: '$line' looks like a credential (GR15)"
    done < <(gate_json "$f" | jq -r --arg re "$TOKEN_NAME_RE" '[.jobs[] | (.with // {}) | keys[]] | .[] | select(test($re; "i"))')
  done
  gate_finish GR15
}

@test "GR15: the registry token reaches an environment only in the package-publish composite (from its input) and in the setup-project install (from the login step), and nowhere else under .github/" {
  gate_require_tools yq jq
  gate_discover GR15 .github -type f '(' -name '*.yml' -o -name '*.yaml' ')'
  local files=("${GATE_SUBJECTS[@]}") f key val found_publish=0 found_login=0
  GATE_VIOLATIONS=()
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r key val; do
      if [[ $f == "$PUBLISH_COMPOSITE" && $key == CODEARTIFACT_AUTH_TOKEN && $val == '${{ inputs.auth-token }}' ]]; then
        found_publish=$((found_publish + 1))
      elif [[ $f == "$LOGIN_COMPOSITE" && $key == CODEARTIFACT_AUTH_TOKEN && $val == "$LOGIN_TOKEN_VALUE" ]]; then
        found_login=$((found_login + 1))
      else
        gate_violation "$f" "env '$key' carries a registry token ('$val'): only $PUBLISH_COMPOSITE (from \${{ inputs.auth-token }}) and $LOGIN_COMPOSITE (from $LOGIN_TOKEN_VALUE) may set CODEARTIFACT_AUTH_TOKEN (GR15)"
      fi
    done < <(gate_json "$f" | jq -r --arg re "$TOKEN_ENV_RE" '[.. | objects | select(has("env")) | .env | objects | to_entries[] | select(.key | test($re)) | [.key, (.value | tostring)]] | .[] | @tsv')
  done
  ((found_publish > 0)) || gate_violation "$PUBLISH_COMPOSITE" "does not set CODEARTIFACT_AUTH_TOKEN from inputs.auth-token (a gate that finds nothing proves nothing)"
  ((found_login == 1)) || gate_violation "$LOGIN_COMPOSITE" "must set CODEARTIFACT_AUTH_TOKEN from $LOGIN_TOKEN_VALUE in exactly one step (found $found_login)"
  gate_finish GR15
}

@test "GR15: in the package scripts the token is a reference in the npmrc, is masked before it is written, and the publish runs with scripts off and the registry forced" {
  gate_require_tools yq jq
  gate_discover GR15 scripts -maxdepth 1 -type f -name 'package-*.sh'
  local scripts=("${GATE_SUBJECTS[@]}") f n line first_out first_mask asked_token=0 published=0
  local ref_re='_authToken=[\]?[$][{][A-Z_]+[}]'
  GATE_VIOLATIONS=()
  for f in "${scripts[@]}"; do
    # every _authToken in the file is a reference to a variable (npm expands it), never a value
    while IFS=: read -r n line; do
      [[ $line =~ $ref_re ]] || gate_violation "$f" "line $n writes an _authToken that is not a \${VAR} reference (GR15)"
    done < <(grep -nE '_authToken' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    # nothing persistent: no login helper, no npm config set, no write to a user or project .npmrc
    while IFS=: read -r n line; do
      gate_violation "$f" "line $n persists registry configuration ('codeartifact login', 'npm config set' or a write to .npmrc): the token lives in one process only (GR15)"
    done < <(grep -nE 'codeartifact login|npm config set|npm login|>>?[[:space:]]*("?\$HOME"?|~|\.)?/?\.npmrc' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if grep -q 'get-authorization-token' "$GATES_ROOT/$f"; then
      asked_token=$((asked_token + 1))
      first_mask="$(grep -nE '^[[:space:]]*mask "' "$GATES_ROOT/$f" | head -n1 | cut -d: -f1 || true)"
      first_out="$(grep -nF 'GITHUB_OUTPUT' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'require_env' | head -n1 | cut -d: -f1 || true)"
      if [[ -z $first_mask ]]; then
        gate_violation "$f" "asks for an authorization token but never masks it (GR15)"
      elif [[ -n $first_out && $first_mask -gt $first_out ]]; then
        gate_violation "$f" "writes to GITHUB_OUTPUT (line $first_out) before masking the token (line $first_mask) (GR15)"
      fi
    fi
    while IFS=: read -r n line; do
      published=$((published + 1))
      [[ $line == *--ignore-scripts* ]] || gate_violation "$f" "line $n: npm publish without --ignore-scripts: a lifecycle script of the package would run with the token in its environment (GR15)"
      [[ $line == *--registry* ]] || gate_violation "$f" "line $n: npm publish without an explicit --registry (GR15)"
    done < <(grep -nE 'npm publish' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'die ' || true)
  done
  ((asked_token > 0)) || gate_violation "scripts" "no package script asks for an authorization token (a gate that finds nothing proves nothing)"
  ((published > 0)) || gate_violation "scripts" "no package script runs npm publish (a gate that finds nothing proves nothing)"
  gate_finish GR15
}
