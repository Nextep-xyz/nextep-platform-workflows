#!/usr/bin/env bats
# Registry login (SPEC.md section 0, "Enmienda Login del registry"): the optional OIDC login to CodeArtifact that lets the gates and the
# deploys install private packages. Subjects are discovered on disk (every composite, every script, every deploy workflow) and every
# gate fails when it finds none:
#   GL1  the login is optional and lives only in setup-project, behind `registry-role-arn != ''`;
#   GL2  the token output is read by exactly one step, the install, and only through that step's env:;
#   GL3  the scripts mask what is secret before it is written, never write to $GITHUB_ENV or to a persistent .npmrc, and the
#        user config holds a reference to the token, never the value;
#   GL4  every setup-project call of a deploy workflow passes the registry inputs from the workflow's own inputs, and a job that
#        passes a role holds id-token (the permission itself is fenced by G2, see permissions.bats).

load 'lib/gates'

LOGIN_COMPOSITE=.github/actions/setup-project/action.yml
LOGIN_INPUTS=(registry-role-arn codeartifact-domain codeartifact-domain-owner codeartifact-repository registry-scope aws-region)

# non-comment lines of a file that match an ERE, as "line:text"
code_lines() { # code_lines <file> <ere>
  grep -nE -- "$2" "$GATES_ROOT/$1" | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

@test "GL1: the login is optional, lives only in setup-project and runs behind registry-role-arn != ''" {
  gate_require_tools yq jq
  gate_discover GL1 .github/actions -type f -name action.yml
  local files=("${GATE_SUBJECTS[@]}") f users=() json i n
  GATE_VIOLATIONS=()
  for f in "${files[@]}"; do
    grep -q 'registry-login\.sh' "$GATES_ROOT/$f" && users+=("$f")
  done
  ((${#users[@]} > 0)) || gate_violation ".github/actions" "no composite runs registry-login.sh (a gate that finds nothing proves nothing)"
  for f in "${users[@]}"; do
    [[ $f == "$LOGIN_COMPOSITE" ]] || gate_violation "$f" "runs registry-login.sh: the login lives only in setup-project (a composite cannot call another one, G11)"
  done
  if [[ -f $GATES_ROOT/$LOGIN_COMPOSITE ]]; then
    json="$(gate_json "$LOGIN_COMPOSITE")"
    for i in "${LOGIN_INPUTS[@]}"; do
      jq -e --arg i "$i" '.inputs[$i] != null and ((.inputs[$i].default // null) == "") and ((.inputs[$i].required // false) == false)' <<<"$json" >/dev/null ||
        gate_violation "$LOGIN_COMPOSITE" "input '$i' must exist, be optional and default to empty: an empty registry-role-arn must leave the install exactly as it was"
    done
    n="$(jq '[.runs.steps[] | select((.run // "") | contains("registry-login.sh"))] | length' <<<"$json")"
    if [[ $n != 1 ]]; then
      gate_violation "$LOGIN_COMPOSITE" "exactly one step must run registry-login.sh (found $n)"
    else
      jq -e --arg want "inputs.registry-role-arn!=''" \
        '[.runs.steps[] | select((.run // "") | contains("registry-login.sh"))][0] | ((.if // "") | gsub("\\$\\{\\{|\\}\\}|\\s"; "")) == $want' <<<"$json" >/dev/null ||
        gate_violation "$LOGIN_COMPOSITE" "the step that runs registry-login.sh must carry exactly 'if: inputs.registry-role-arn != \"\"': with an empty role nothing is assumed"
      jq -e '[.runs.steps[] | select((.run // "") | contains("registry-login.sh"))][0] | (.id // "") != "" and (has("continue-on-error") | not)' <<<"$json" >/dev/null ||
        gate_violation "$LOGIN_COMPOSITE" "the login step needs an id and no continue-on-error: a failed login fails the install it was meant for"
    fi
    jq -e '(.outputs // {}) | length == 0' <<<"$json" >/dev/null ||
      gate_violation "$LOGIN_COMPOSITE" "the composite declares outputs: the registry token must not leave it"
  else
    gate_violation "$LOGIN_COMPOSITE" "does not exist"
  fi
  gate_finish GL1
}

@test "GL2: the token output is read by exactly one step, the install, and only through that step's env:" {
  gate_require_tools yq jq
  gate_discover GL2 .github/actions/setup-project -maxdepth 1 -type f -name action.yml
  local f json id ref readers
  GATE_VIOLATIONS=()
  for f in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$f")"
    id="$(jq -r '[.runs.steps[] | select((.run // "") | contains("registry-login.sh")) | .id][0] // ""' <<<"$json")"
    [[ -n $id ]] || { gate_violation "$f" "the login step has no id: its output cannot be read (and a gate that finds nothing proves nothing)"; continue; }
    ref="steps.$id.outputs.token"
    readers="$(jq -r --arg ref "$ref" '[.runs.steps[] | select((((.env // {}) | tostring) + ((.with // {}) | tostring) + (.run // "") + (.if // "")) | contains($ref)) | (.name // .id // "unnamed")] | length' <<<"$json")"
    [[ $readers == 1 ]] || gate_violation "$f" "the token output ($ref) must be read by exactly one step (found $readers)"
    jq -e --arg ref "$ref" '[.runs.steps[] | select((((.env // {}) | tostring) + ((.with // {}) | tostring) + (.run // "") + (.if // "")) | contains($ref))]
      | all((.run // "") | test("install-dirs\\.sh\"? install"))' <<<"$json" >/dev/null ||
      gate_violation "$f" "the token output is read by a step that does not run the immutable install (install-dirs.sh install)"
    jq -e --arg want "\${{ $ref }}" '[.runs.steps[] | select((.run // "") | test("install-dirs\\.sh\"? install"))] | (length == 1) and all(.env.CODEARTIFACT_AUTH_TOKEN == $want)' <<<"$json" >/dev/null ||
      gate_violation "$f" "the install step must receive the token as env CODEARTIFACT_AUTH_TOKEN: \${{ $ref }} (and nowhere else: not in with:, not in run:)"
  done
  gate_finish GL2
}

@test "GL3: the scripts mask before they write, never touch \$GITHUB_ENV or a persistent .npmrc, and the user config holds a reference, not the token" {
  gate_require_tools jq
  gate_discover GL3 scripts -maxdepth 1 -type f '(' -name registry-login.sh -o -name install-dirs.sh ')'
  local scripts=("${GATE_SUBJECTS[@]}") f n line out_line var m
  local ref_re='_authToken=[\]?[$][{][A-Z_]+[}]'
  GATE_VIOLATIONS=()
  ((${#scripts[@]} == 2)) || gate_violation "scripts" "expected registry-login.sh and install-dirs.sh, discovered ${#scripts[@]} (a gate that finds nothing proves nothing)"
  for f in "${scripts[@]}"; do
    while IFS=: read -r n line; do
      gate_violation "$f" "line $n writes to or reads \$GITHUB_ENV: the registry credentials and the token never reach the runner env file"
    done < <(code_lines "$f" 'GITHUB_ENV')
    while IFS=: read -r n line; do
      gate_violation "$f" "line $n persists registry configuration ('codeartifact login', 'npm config set', 'npm login' or a write to a .npmrc): the token lives in one process only"
    done < <(code_lines "$f" 'codeartifact login|npm config set|npm login|>>?[[:space:]]*("?\$HOME"?|~|\.)?/?\.npmrc')
    while IFS=: read -r n line; do
      [[ $line =~ $ref_re ]] || gate_violation "$f" "line $n writes an _authToken that is not a \${VAR} reference: the user config holds a reference, never the token"
    done < <(code_lines "$f" '_authToken')
    while IFS=: read -r n line; do
      gate_violation "$f" "line $n exports AWS credentials: the registry role credentials live in the env of the CodeArtifact calls only"
    done < <(code_lines "$f" '(^|[[:space:];])export[[:space:]]+AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)')
  done
  # registry-login.sh: everything secret is masked, and all of it BEFORE anything is written to GITHUB_OUTPUT
  f=scripts/registry-login.sh
  if [[ -f $GATES_ROOT/$f ]]; then
    out_line="$(code_lines "$f" 'GITHUB_OUTPUT' | grep -v 'require_env' | head -n1 | cut -d: -f1 || true)"
    [[ -n $out_line ]] || gate_violation "$f" "never writes to GITHUB_OUTPUT (a gate that finds nothing proves nothing)"
    for var in jwt sk st token; do
      m="$(code_lines "$f" "^[[:space:]]*mask \"\\\$$var\"" | head -n1 | cut -d: -f1 || true)"
      if [[ -z $m ]]; then
        gate_violation "$f" "never masks \$$var"
      elif [[ -n $out_line && $m -gt $out_line ]]; then
        gate_violation "$f" "masks \$$var (line $m) after writing to GITHUB_OUTPUT (line $out_line)"
      fi
    done
  fi
  # install-dirs.sh: the user config is temporary, removed on exit, and handed over through NPM_CONFIG_USERCONFIG only
  f=scripts/install-dirs.sh
  if [[ -f $GATES_ROOT/$f ]]; then
    [[ -n "$(code_lines "$f" 'mktemp')" ]] || gate_violation "$f" "the user config is not a mktemp file"
    [[ -n "$(code_lines "$f" "trap '?\"?rm -f")" ]] || gate_violation "$f" "no trap removes the temporary user config"
    [[ -n "$(code_lines "$f" 'export NPM_CONFIG_USERCONFIG=')" ]] || gate_violation "$f" "the user config is not handed over through NPM_CONFIG_USERCONFIG"
  fi
  gate_finish GL3
}

@test "GL4: every setup-project call of a deploy workflow passes the registry inputs from the workflow's own inputs, and a job that passes the role holds id-token" {
  gate_require_tools yq jq
  gate_discover_deploy_workflows GL4
  local wf json k calls job
  GATE_VIOLATIONS=()
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    # the workflow declares the five inputs, optional and empty by default (their equality with the contract is G12)
    for k in registry-role-arn codeartifact-domain codeartifact-domain-owner codeartifact-repository registry-scope; do
      jq -e --arg k "$k" '.on.workflow_call.inputs[$k] | . != null and (.type == "string") and ((.default // null) == "") and ((.required // false) == false)' <<<"$json" >/dev/null ||
        gate_violation "$wf" "input '$k' must be a string, optional and empty by default: an empty registry-role-arn leaves the workflow exactly as it was"
    done
    calls="$(jq '[.jobs[].steps[]? | select((.uses // "") | test("/actions/setup-project@"))] | length' <<<"$json")"
    ((calls > 0)) || { gate_violation "$wf" "no setup-project call was found (a gate that finds nothing proves nothing)"; continue; }
    # every call passes the six composite inputs from the workflow inputs of the same name: a job that forgets one installs without the private packages
    for k in "${LOGIN_INPUTS[@]}"; do
      jq -e --arg k "$k" --arg want "\${{ inputs.$k }}" '[.jobs[].steps[]? | select((.uses // "") | test("/actions/setup-project@"))] | all(.with[$k] == $want)' <<<"$json" >/dev/null ||
        gate_violation "$wf" "a setup-project call does not pass $k: \${{ inputs.$k }} (every job that installs dependencies must take the registry login, or it installs without the private packages)"
    done
    # a job that passes the role needs id-token: without it the login fails at run time
    while IFS= read -r job; do
      gate_violation "$wf" "job '$job' passes registry-role-arn to setup-project but does not hold id-token: write"
    done < <(jq -r '.jobs | to_entries[] | select([.value.steps[]? | select((.uses // "") | test("/actions/setup-project@")) | .with["registry-role-arn"]] | any(. != null)) | select(.value.permissions["id-token"]? != "write") | .key' <<<"$json")
  done
  gate_finish GL4
}
