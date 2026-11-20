#!/usr/bin/env bats
# Gates of the packages evidence (composite nextep-packages-evidence + scripts/packages-evidence.sh, docs/runbook.md section 11). The block that
# people screenshot as proof of compliance must be honest, so the rules that make it honest are tests, not prose. Subjects are discovered on disk
# (every lego-*.yml that invokes the composite), a gate that finds none fails, and every gate is verified in red by test/bats/gates-red.bats.
#   PE-REQUIRED  the workflows that must carry the evidence do carry it (and an entry of that list whose workflow vanished fails as stale)
#   PE-ALWAYS    the step runs even when the validation failed (`always()`), can be switched off by `inputs.packages-evidence`, and so does every
#                step of the composite
#   PE-OUTCOME   the validations it reports are `steps.<id>.outcome` of steps that exist, run BEFORE it, and are validations (a fixed text is the
#                defect this gate exists to forbid); every validation step of the job is reported (none can be left out)
#   PE-INPUT     `packages-evidence` is a boolean that defaults to true, in the workflow and in its contract
#   PE-SAFE      the composite and the script: no network, no install, no caller command, no secret, no environment dump, a clean env for the binary

load 'lib/gates'

# Workflows that must show the evidence. Declared here and found on disk (SPEC corollary b): an entry whose workflow no longer exists fails as stale.
PE_REQUIRED=(lego-node-ci lego-aws-cicd)
# The composites whose steps ARE the validations of a job. A step of the job that uses one of them must be reported by the evidence step.
PE_VALIDATION_COMPOSITES=(node-ci quality-gate)
# The environment the composite may hand to its script (SCRIPTS is the path of the scripts; the rest are the data of the block).
PE_COMPOSITE_ENV=(SCRIPTS INSTALL_DIRS PACKAGE_MANAGER VALIDATIONS JOB_WORKFLOW_REF)
PE_COMPOSITE=.github/actions/nextep-packages-evidence/action.yml
PE_SCRIPT=scripts/packages-evidence.sh

code_lines() { grep -vE '^[[:space:]]*#' "$GATES_ROOT/$1" || true; }

# wired_steps <workflow json>: one compact object per step that invokes the composite: {job, idx, step}
wired_steps() {
  jq -c '.jobs | to_entries[] | .key as $j | (.value.steps // []) | to_entries[]
    | select((.value.uses // "") | test("/\\.github/actions/nextep-packages-evidence@")) | {job: $j, idx: .key, step: .value}' <<<"$1"
}

# composite_of <uses string>: the name of the internal composite in `owner/repo/.github/actions/<name>@ref` (empty for anything else)
composite_of() { sed -nE 's#.*/\.github/actions/([a-z0-9-]+)@.*#\1#p' <<<"$1"; }

@test "PE-REQUIRED: lego-node-ci and lego-aws-cicd invoke the packages evidence, and so does every other workflow that calls the composite (found on disk)" {
  gate_require_tools yq jq
  gate_discover_lego_workflows PE-REQUIRED
  local workflows=("${GATE_SUBJECTS[@]}") wf name n total=0
  GATE_VIOLATIONS=()
  for wf in "${workflows[@]}"; do
    n="$(wired_steps "$(gate_json "$wf")" | grep -c . || true)"
    total=$((total + n))
    name="$(basename "$wf" .yml)"
    if [[ " ${PE_REQUIRED[*]} " == *" $name "* ]]; then
      [[ $n == 1 ]] || gate_violation "$wf" "must invoke the nextep-packages-evidence composite exactly once (found $n)"
    elif ((n > 1)); then
      # not required, but a workflow that uses it is subject to every other PE gate (it is discovered, not listed)
      gate_violation "$wf" "invokes the nextep-packages-evidence composite $n times (once at most)"
    fi
  done
  for name in "${PE_REQUIRED[@]}"; do
    [[ -f $GATES_ROOT/.github/workflows/$name.yml ]] || gate_violation ".github/workflows/$name.yml" "is in the PE-REQUIRED list of the gate but does not exist (stale entry)"
  done
  ((total > 0)) || gate_violation ".github/workflows" "no workflow invokes the nextep-packages-evidence composite (a gate that finds nothing proves nothing)"
  [[ -f $GATES_ROOT/$PE_COMPOSITE ]] || gate_violation "$PE_COMPOSITE" "the composite does not exist"
  gate_finish PE-REQUIRED
}

@test "PE-ALWAYS: the evidence step runs when the validation failed and can be switched off; every step of the composite runs always() too" {
  gate_require_tools yq jq
  gate_discover_lego_workflows PE-ALWAYS
  local workflows=("${GATE_SUBJECTS[@]}") wf w cond found=0
  GATE_VIOLATIONS=()
  for wf in "${workflows[@]}"; do
    while IFS= read -r w; do
      [[ -n $w ]] || continue
      found=$((found + 1))
      cond="$(jq -r '.step.if // ""' <<<"$w")"
      [[ $cond == *"always()"* ]] ||
        gate_violation "$wf" "the evidence step of job '$(jq -r .job <<<"$w")' has no always() in its 'if:' (found '${cond:-none}'): it would not be written when the validation failed"
      [[ $cond == *"inputs.packages-evidence"* ]] ||
        gate_violation "$wf" "the evidence step of job '$(jq -r .job <<<"$w")' is not conditioned on inputs.packages-evidence (it could not be switched off)"
      jq -e '.step["continue-on-error"] != true' <<<"$w" >/dev/null ||
        gate_violation "$wf" "the evidence step sets continue-on-error: the script itself never fails the job, and the gate G-COE forbids it here"
    done < <(wired_steps "$(gate_json "$wf")")
  done
  ((found > 0)) || gate_violation ".github/workflows" "PE-ALWAYS found no evidence step (a gate that finds nothing proves nothing)"
  if [[ -f $GATES_ROOT/$PE_COMPOSITE ]]; then
    gate_json "$PE_COMPOSITE" | jq -e '[.runs.steps[] | select((.if // "") | contains("always()") | not)] | length == 0' >/dev/null ||
      gate_violation "$PE_COMPOSITE" "a step of the composite has no 'if: always()': with a failed validation before it, it would be skipped"
    gate_json "$PE_COMPOSITE" | jq -e '[.runs.steps[]] | length > 0' >/dev/null || gate_violation "$PE_COMPOSITE" "the composite has no steps"
  else
    gate_violation "$PE_COMPOSITE" "the composite does not exist"
  fi
  gate_finish PE-ALWAYS
}

@test "PE-OUTCOME: the validations are steps.<id>.outcome of validation steps that exist and run before the evidence; none is left out, none is a fixed text" {
  gate_require_tools yq jq
  gate_discover_lego_workflows PE-OUTCOME
  local workflows=("${GATE_SUBJECTS[@]}") wf w job idx json vals line id at i lines n step_id c uses found=0 name
  local outcome_re='^[^=]+=\$\{\{ steps\.([A-Za-z0-9_-]+)\.outcome \}\}$'
  GATE_VIOLATIONS=()
  declare -A reported_composites=()
  for wf in "${workflows[@]}"; do
    json="$(gate_json "$wf")"
    while IFS= read -r w; do
      [[ -n $w ]] || continue
      found=$((found + 1))
      job="$(jq -r .job <<<"$w")"
      idx="$(jq -r .idx <<<"$w")"
      vals="$(jq -r '.step.with.validations // ""' <<<"$w")"
      lines=0
      declare -A referenced=()
      while IFS= read -r line; do
        [[ -n ${line//[[:space:]]/} ]] || continue
        lines=$((lines + 1))
        if [[ $line =~ $outcome_re ]]; then
          id="${BASH_REMATCH[1]}"
          at="$(jq -r --arg j "$job" --arg id "$id" '(.jobs[$j].steps // []) | map(.id // "") | index($id) // -1' <<<"$json")"
          if ((at < 0)); then
            gate_violation "$wf" "job '$job': the validation '${line%%=*}' reads steps.$id.outcome but no step of the job has that id"
          elif ((at >= idx)); then
            gate_violation "$wf" "job '$job': the validation '${line%%=*}' reads steps.$id.outcome of a step that does not run BEFORE the evidence step"
          else
            referenced[$id]=1
            uses="$(jq -r --argjson a "$at" --arg j "$job" '.jobs[$j].steps[$a].uses // ""' <<<"$json")"
            c="$(composite_of "$uses")"
            if [[ -z $c || " ${PE_VALIDATION_COMPOSITES[*]} " != *" $c "* ]]; then
              gate_violation "$wf" "job '$job': the validation '${line%%=*}' reads steps.$id.outcome, which is not a validation step (it must use one of: ${PE_VALIDATION_COMPOSITES[*]})"
            else
              reported_composites[$c]=1
            fi
          fi
        else
          gate_violation "$wf" "job '$job': the validation line '$line' is not '<label>=\${{ steps.<id>.outcome }}': a fixed value is exactly what this block must never carry"
        fi
      done <<<"$vals"
      ((lines > 0)) || gate_violation "$wf" "job '$job': the evidence step reports no validation"
      # every validation step of the job is reported
      n="$(jq -r --arg j "$job" '(.jobs[$j].steps // []) | length' <<<"$json")"
      for ((i = 0; i < n; i++)); do
        uses="$(jq -r --argjson a "$i" --arg j "$job" '.jobs[$j].steps[$a].uses // ""' <<<"$json")"
        c="$(composite_of "$uses")"
        [[ -n $c && " ${PE_VALIDATION_COMPOSITES[*]} " == *" $c "* ]] || continue
        step_id="$(jq -r --argjson a "$i" --arg j "$job" '.jobs[$j].steps[$a].id // ""' <<<"$json")"
        name="$(jq -r --argjson a "$i" --arg j "$job" '.jobs[$j].steps[$a].name // "(unnamed)"' <<<"$json")"
        if [[ -z $step_id ]]; then
          gate_violation "$wf" "job '$job': the step '$name' uses the $c validation composite and has no id, so its outcome cannot be reported"
        elif [[ -z ${referenced[$step_id]:-} ]]; then
          gate_violation "$wf" "job '$job': the validation step '$step_id' ($c) is not reported by the evidence step"
        fi
      done
      unset referenced
    done < <(wired_steps "$json")
  done
  ((found > 0)) || gate_violation ".github/workflows" "PE-OUTCOME found no evidence step (a gate that finds nothing proves nothing)"
  # an entry of the validation-composite list that no evidence step reports is stale
  for c in "${PE_VALIDATION_COMPOSITES[@]}"; do
    [[ -n ${reported_composites[$c]:-} ]] || gate_violation "$PE_COMPOSITE" "'$c' is in PE_VALIDATION_COMPOSITES but no evidence step reports a step that uses it (stale entry)"
  done
  gate_finish PE-OUTCOME
}

@test "PE-INPUT: packages-evidence is a boolean that defaults to true, in every workflow that carries the evidence and in its contract" {
  gate_require_tools yq jq
  gate_discover_lego_workflows PE-INPUT
  local workflows=("${GATE_SUBJECTS[@]}") wf name contract found=0
  GATE_VIOLATIONS=()
  for wf in "${workflows[@]}"; do
    [[ -n "$(wired_steps "$(gate_json "$wf")")" ]] || continue
    found=$((found + 1))
    name="$(basename "$wf" .yml)"
    contract="contracts/$name.contract.yml"
    gate_json "$wf" | jq -e '.on.workflow_call.inputs["packages-evidence"] | (.type == "boolean" and .default == true and ((.required // false) == false))' >/dev/null ||
      gate_violation "$wf" "input 'packages-evidence' must be a boolean, not required, with default true"
    if [[ -f $GATES_ROOT/$contract ]]; then
      gate_json "$contract" | jq -e '.inputs["packages-evidence"] | (.type == "boolean" and .default == true)' >/dev/null ||
        gate_violation "$contract" "input 'packages-evidence' must be a boolean with default true (as in the workflow)"
    else
      gate_violation "$wf" "has no contract ($contract)"
    fi
  done
  ((found > 0)) || gate_violation ".github/workflows" "PE-INPUT found no workflow with the evidence (a gate that finds nothing proves nothing)"
  gate_finish PE-INPUT
}

@test "PE-SAFE: the composite hands the script only its data; the script has no network, no install, no secret, no environment dump and runs the binary with a clean environment" {
  gate_require_tools yq jq
  gate_discover PE-SAFE .github/actions/nextep-packages-evidence scripts/packages-evidence.sh -type f
  GATE_VIOLATIONS=()
  local key line lines
  if [[ -f $GATES_ROOT/$PE_COMPOSITE ]]; then
    # the environment of every step of the composite: only the declared names
    while IFS= read -r key; do
      [[ " ${PE_COMPOSITE_ENV[*]} " == *" $key "* ]] ||
        gate_violation "$PE_COMPOSITE" "hands the variable '$key' to the script: only ${PE_COMPOSITE_ENV[*]} are allowed (no secret, no token)"
    done < <(gate_json "$PE_COMPOSITE" | jq -r '[.runs.steps[].env // {} | keys[]] | unique | .[]')
    lines="$(code_lines "$PE_COMPOSITE" | grep -nE 'secrets\.|github\.token|GITHUB_TOKEN|GH_TOKEN|id-token|continue-on-error|permissions:' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$PE_COMPOSITE" "line ${line%%:*} mentions a secret, the token, id-token or permissions: the evidence needs none of them"
    done <<<"$lines"
    gate_json "$PE_COMPOSITE" | jq -e '[.runs.steps[] | select(has("uses"))] | length == 0' >/dev/null ||
      gate_violation "$PE_COMPOSITE" "uses another action: the evidence is one script and nothing else (gate G11 forbids a composite inside a composite)"
    gate_json "$PE_COMPOSITE" | jq -e '[.runs.steps[].run // ""] | all(contains("packages-evidence.sh"))' >/dev/null ||
      gate_violation "$PE_COMPOSITE" "a step runs something other than scripts/packages-evidence.sh"
  fi
  if [[ -f $GATES_ROOT/$PE_SCRIPT ]]; then
    # no network, no install, no tool that could fetch or run what is not already on disk, no caller command
    lines="$(code_lines "$PE_SCRIPT" | grep -nE '(^|[^A-Za-z0-9_.-])(curl|wget|gh|aws|az|npx|yarn|docker|ssh|nc|ncat)([^A-Za-z0-9_-]|$)|(npm|pnpm)[[:space:]]+(i|install|ci|add|dlx|exec|run|x|update|publish)([^A-Za-z]|$)' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$PE_SCRIPT" "line ${line%%:*} runs a network, install or package-manager command: the evidence reads files and runs the installed binary only"
    done <<<"$lines"
    # no secret read, no environment dump, no trace
    lines="$(code_lines "$PE_SCRIPT" | grep -nE 'INTERNAL_DENYLIST|CODEARTIFACT|GITHUB_TOKEN|GH_TOKEN|secrets\.|printenv|declare -p|export -p|(^|[;&|[:space:]])env([[:space:]]*($|[|;>&]))|set -[a-z]*x|BASH_XTRACEFD' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$PE_SCRIPT" "line ${line%%:*} reads a secret, dumps the environment or traces the shell"
    done <<<"$lines"
    # the binary of the installed package runs with a clean environment, with a timeout, from its path (never through a package manager)
    code_lines "$PE_SCRIPT" | grep -qE 'env -i PATH=' ||
      gate_violation "$PE_SCRIPT" "the installed binary must run through 'env -i PATH=…' (a clean environment: no secret of the CI reaches it)"
    code_lines "$PE_SCRIPT" | grep -qE 'timeout [0-9]+ "\./node_modules/\.bin/' ||
      gate_violation "$PE_SCRIPT" "the installed binary must run with a timeout, from ./node_modules/.bin/ (never through npx or pnpm exec, which can fetch)"
    # the roots come from install-dirs.sh (one rule for what a root is), and the script is strict
    code_lines "$PE_SCRIPT" | grep -q 'install-dirs.sh" lockfiles' ||
      gate_violation "$PE_SCRIPT" "must take the package roots from install-dirs.sh lockfiles (the validation the install uses)"
    code_lines "$PE_SCRIPT" | grep -qE '^set -euo pipefail$' || gate_violation "$PE_SCRIPT" "must start with 'set -euo pipefail'"
  fi
  gate_finish PE-SAFE
}
