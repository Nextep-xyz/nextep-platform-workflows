#!/usr/bin/env bats
# Gates of the packages policy by environment (docs/runbook.md section 12). Subjects are discovered on disk (the scripts, the composites and the
# workflows), a gate that finds none fails, and every gate is verified in red by test/bats/gates-red-enforcement.bats.
#   EN-SINGLE  ONE function turns an environment into a mode (scripts/lib/enforcement.sh). No other script, composite or workflow compares an
#              environment name to decide it, and none writes the mode as a literal: a second decision is a second place to forget prod
#   EN-ENV     every call site of run-command.sh (the one door of every command of the caller: lint, test, build, infra, post-deploy) hands it the
#              environment (APP_ENV: ${{ inputs.environment }}) when the composite has one, and run-command.sh derives NEXTEP_GUARDRAILS_MODE from it
#              through the function: a call site that forgets APP_ENV would run its commands in enforce inside prod
#   EN-SAFE    the policy (composite + script) and the libraries it shares: no network, no install, no secret, no id-token, no environment dump,
#              no caller command, no `continue-on-error` (the warning is an exit code); the catalog is read from the profile only, never from the
#              environment of the run
#   EN-WIRE / EN-COE / EN-NOKNOB / EN-SAFE-GUARD  the wiring of the workflows: the guard and the policy are in the gate job, in order, always on (no
#              input switches them off, and the one input whose name is about the guard is the COMMAND it runs), with no continue-on-error

load 'lib/gates'

ENFORCEMENT_LIB=scripts/lib/enforcement.sh
POLICY_SCRIPT=scripts/packages-policy.sh
POLICY_COMPOSITE=.github/actions/nextep-packages-policy/action.yml
# The environment the policy composite may hand to its script (SCRIPTS is the path of the scripts; the rest are the data of the policy).
EN_COMPOSITE_ENV=(SCRIPTS ENVIRONMENT INSTALL_DIRS PACKAGE_MANAGER ROOT_KINDS GUARDRAILS_RESULT)
# What marks a file as part of the packages policy: it names the mode, the function or the policy itself. Found on disk, never listed.
EN_SUBJECT_RE='enforcement_mode|NEXTEP_GUARDRAILS_MODE|lib/enforcement\.sh|packages-policy|package-guardrails'
# A comparison of an environment name, or a case pattern on one: `== prod`, `!= 'dev'`, `=~ stg`, `prod)`, `dev|stg)`.
EN_ENV_COMPARE_RE='(==|!=|=~)[[:space:]]*["'"'"']?(dev|stg|prod)["'"'"']?([^A-Za-z0-9_-]|$)|^[[:space:]]*["'"'"']?(dev|stg|prod)["'"'"']?([[:space:]]*[|)])|(environment|ENVIRONMENT|APP_ENV)[[:space:]]*=[[:space:]]*["'"'"']?(dev|stg|prod)["'"'"']?([^A-Za-z0-9_-]|$)'
# The mode written as a literal: `NEXTEP_GUARDRAILS_MODE=warn`, `NEXTEP_GUARDRAILS_MODE: enforce`, `mode=warn`.
EN_MODE_LITERAL_RE='(NEXTEP_GUARDRAILS_MODE|guardrails_mode|GUARDRAILS_MODE|(^|[^A-Za-z0-9_])mode)[[:space:]]*[=:][[:space:]]*["'"'"']?(warn|enforce)["'"'"']?([^A-Za-z0-9_-]|$)'

code_lines() { grep -vE '^[[:space:]]*#' "$GATES_ROOT/$1" || true; }

# subjects_of_the_policy: every file of scripts/ and .github/ that names the mode, the function or the policy, except the function's own file
policy_subjects() {
  (cd "$GATES_ROOT" && grep -rlE "$EN_SUBJECT_RE" scripts .github 2>/dev/null | grep -v "^$ENFORCEMENT_LIB\$" | sort -u) || true
}

@test "EN-SINGLE: lib/enforcement.sh declares the function once, and no script, composite or workflow decides a mode from an environment name or writes it as a literal" {
  gate_discover EN-SINGLE scripts/lib -maxdepth 1 -type f -name 'enforcement.sh'
  local f n=0 line lines subjects=()
  GATE_VIOLATIONS=()
  [[ "$(code_lines "$ENFORCEMENT_LIB" | grep -cE '^enforcement_mode\(\)')" == 1 ]] ||
    gate_violation "$ENFORCEMENT_LIB" "must declare 'enforcement_mode()' exactly once"
  while IFS= read -r f; do [[ -n $f ]] && subjects+=("$f"); done < <(policy_subjects)
  for f in "${subjects[@]}"; do
    n=$((n + 1))
    lines="$(code_lines "$f" | grep -nE "$EN_ENV_COMPARE_RE" || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$f" "decides something from the name of an environment (code line ${line%%:*}): the mode comes only from enforcement_mode in $ENFORCEMENT_LIB"
    done <<<"$lines"
    lines="$(code_lines "$f" | grep -nE "$EN_MODE_LITERAL_RE" || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$f" "writes the mode as a literal (code line ${line%%:*}): it must be the answer of enforcement_mode, never a value written here"
    done <<<"$lines"
  done
  ((n > 0)) || gate_violation "scripts" "no script or composite uses the mode or the policy (a gate that finds nothing proves nothing)"
  gate_finish EN-SINGLE
}

# call_site_scripts: the scripts (other than run-command.sh) that call run-command.sh, one basename per line (found on disk)
call_site_scripts() {
  (cd "$GATES_ROOT" && grep -lE 'run-command\.sh' scripts/*.sh 2>/dev/null | grep -v '^scripts/run-command\.sh$' | xargs -r -n1 basename | sort -u) || true
}

@test "EN-ENV: every step that reaches run-command.sh hands over APP_ENV from the environment input, and run-command.sh derives the mode from it with the function" {
  gate_require_tools yq jq
  gate_discover EN-ENV .github -type f -name '*.yml' -path '*/actions/*'
  local composites=("${GATE_SUBJECTS[@]}") f json i name total=0 re="run-command\\.sh" script has_env
  GATE_VIOLATIONS=()
  while IFS= read -r script; do [[ -n $script ]] && re+="|${script//./\\.}"; done < <(call_site_scripts)
  # the composites: a step whose script reaches run-command.sh (directly, or through a script that calls it) belongs to a composite that has the
  # input `environment` => the step must map APP_ENV to it. A composite without an environment (the package family has none) is not subject: its
  # commands run with no APP_ENV, which the function reads as enforce.
  for f in "${composites[@]}"; do
    json="$(gate_json "$f")"
    has_env="$(jq -r '(.inputs // {}) | has("environment")' <<<"$json")"
    while IFS= read -r i; do
      [[ -n $i ]] || continue
      total=$((total + 1))
      name="$(jq -r --argjson i "$i" '.runs.steps[$i].name // ("#" + ($i | tostring))' <<<"$json")"
      if [[ $has_env == true ]]; then
        jq -e --argjson i "$i" '.runs.steps[$i].env.APP_ENV == "${{ inputs.environment }}"' <<<"$json" >/dev/null ||
          gate_violation "$f" "step '$name' reaches run-command.sh without 'APP_ENV: \${{ inputs.environment }}': its commands would run in enforce inside prod"
      fi
    done < <(jq -r --arg re "$re" '(.runs.steps // []) | to_entries[] | select((.value.run // "") | test($re)) | .key' <<<"$json")
  done
  # the workflows: a step of a workflow that runs it directly must hand over APP_ENV the same way
  local wf job
  while IFS= read -r wf; do
    [[ -n $wf ]] || continue
    json="$(gate_json "$wf")"
    while IFS= read -r job; do
      [[ -n $job ]] || continue
      total=$((total + 1))
      gate_violation "$wf" "job '$job' runs run-command.sh in a step without 'APP_ENV: \${{ inputs.environment }}'"
    done < <(jq -r --arg ok '${{ inputs.environment }}' '.jobs | to_entries[] | .key as $j | select([(.value.steps // [])[] | select((.run // "") | test("run-command[.]sh")) | select((.env.APP_ENV // "") != $ok)] | length > 0) | $j' <<<"$json")
    total=$((total + $(jq -r '[.jobs[].steps[]? | select((.run // "") | test("run-command[.]sh"))] | length' <<<"$json")))
  done < <(cd "$GATES_ROOT" && find .github/workflows -maxdepth 1 -type f -name '*.yml' 2>/dev/null | sed 's|^\./||' | sort)
  ((total > 0)) || gate_violation ".github/actions" "no step reaches run-command.sh (a gate that finds nothing proves nothing)"
  # run-command.sh itself: the mode is the answer of the function for APP_ENV, exported to the command
  if [[ -f $GATES_ROOT/scripts/run-command.sh ]]; then
    code_lines scripts/run-command.sh | grep -q 'source .*lib/enforcement\.sh' ||
      gate_violation "scripts/run-command.sh" "must source lib/enforcement.sh"
    code_lines scripts/run-command.sh | grep -qE 'enforcement_mode "\$\{APP_ENV-\}"' ||
      gate_violation "scripts/run-command.sh" "must derive the mode with 'enforcement_mode \"\${APP_ENV-}\"'"
    code_lines scripts/run-command.sh | grep -qE 'export NEXTEP_GUARDRAILS_MODE=' ||
      gate_violation "scripts/run-command.sh" "must export NEXTEP_GUARDRAILS_MODE to the command it runs"
  else
    gate_violation "scripts/run-command.sh" "does not exist"
  fi
  gate_finish EN-ENV
}

@test "EN-SAFE: the policy (composite, script and shared libraries) has no network, install, secret, id-token, environment dump or caller command, no continue-on-error, and reads the catalog only from the profile" {
  gate_require_tools yq jq
  gate_discover EN-SAFE .github/actions/nextep-packages-policy scripts/packages-policy.sh scripts/lib/enforcement.sh scripts/lib/semver.sh scripts/lib/safe-text.sh scripts/lib/guardrails.sh -type f
  local f key line lines
  GATE_VIOLATIONS=()
  if [[ -f $GATES_ROOT/$POLICY_COMPOSITE ]]; then
    while IFS= read -r key; do
      [[ " ${EN_COMPOSITE_ENV[*]} " == *" $key "* ]] ||
        gate_violation "$POLICY_COMPOSITE" "hands the variable '$key' to the script: only ${EN_COMPOSITE_ENV[*]} are allowed (no secret, no token)"
    done < <(gate_json "$POLICY_COMPOSITE" | jq -r '[.runs.steps[].env // {} | keys[]] | unique | .[]')
    lines="$(code_lines "$POLICY_COMPOSITE" | grep -nE 'secrets\.|github\.token|GITHUB_TOKEN|GH_TOKEN|id-token|continue-on-error|permissions:' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$POLICY_COMPOSITE" "code line ${line%%:*} mentions a secret, the token, id-token, permissions or continue-on-error: the policy needs none of them (a warning is an exit code)"
    done <<<"$lines"
    gate_json "$POLICY_COMPOSITE" | jq -e '[.runs.steps[] | select(has("uses"))] | length == 0' >/dev/null ||
      gate_violation "$POLICY_COMPOSITE" "uses another action: the policy is one script and nothing else (gate G11 forbids a composite inside a composite)"
    gate_json "$POLICY_COMPOSITE" | jq -e '[.runs.steps[].run // ""] | all(contains("packages-policy.sh"))' >/dev/null ||
      gate_violation "$POLICY_COMPOSITE" "a step runs something other than scripts/packages-policy.sh"
    gate_json "$POLICY_COMPOSITE" | jq -e '[.runs.steps[] | (.if // "") | contains("!cancelled()")] | all' >/dev/null ||
      gate_violation "$POLICY_COMPOSITE" "every step must carry 'if: \${{ !cancelled() }}': the policy is also evaluated when an earlier validation failed"
  fi
  for f in "${GATE_SUBJECTS[@]}"; do
    [[ $f == *.sh ]] || continue
    lines="$(code_lines "$f" | grep -nE '(^|[^A-Za-z0-9_.-])(curl|wget|gh|aws|az|npx|yarn|docker|ssh|nc|ncat)([^A-Za-z0-9_-]|$)|(npm|pnpm)[[:space:]]+(i|install|ci|add|dlx|exec|run|x|update|publish)([^A-Za-z]|$)' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$f" "code line ${line%%:*} runs a network, install or package-manager command: the policy reads files and runs nothing of the caller"
    done <<<"$lines"
    lines="$(code_lines "$f" | grep -nE 'INTERNAL_DENYLIST|CODEARTIFACT|GITHUB_TOKEN|GH_TOKEN|secrets\.|printenv|declare -p|export -p|(^|[;&|[:space:]])env([[:space:]]*($|[|;>&]))|set -[a-z]*x|BASH_XTRACEFD' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$f" "code line ${line%%:*} reads a secret, dumps the environment or traces the shell"
    done <<<"$lines"
    # the catalog is read from the profile of the platform: a minimum or a recommended version coming from the environment of the run is a knob
    lines="$(code_lines "$f" | grep -nE '\$\{?(MIN|RECOMMENDED)_?VERSION|\$\{?[A-Z_]*(MIN|RECOMMENDED)_VERSION' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$f" "code line ${line%%:*} reads a minimum or recommended version from a variable: the catalog is the profile of the platform and nothing else"
    done <<<"$lines"
  done
  if [[ -f $GATES_ROOT/$POLICY_SCRIPT ]]; then
    code_lines "$POLICY_SCRIPT" | grep -qE '^set -euo pipefail$' || gate_violation "$POLICY_SCRIPT" "must start with 'set -euo pipefail'"
    code_lines "$POLICY_SCRIPT" | grep -qE 'enforcement_mode "\$\{ENVIRONMENT-\}"' ||
      gate_violation "$POLICY_SCRIPT" "must take the mode from 'enforcement_mode \"\${ENVIRONMENT-}\"' (the single function)"
    code_lines "$POLICY_SCRIPT" | grep -qE 'packages-evidence\.sh" findings' ||
      gate_violation "$POLICY_SCRIPT" "must take its verdict from 'packages-evidence.sh findings' (one reading of the disk, never a second one)"
  fi
  gate_finish EN-SAFE
}

# ---- wiring of the workflows (F2) ---------------------------------------------------------------------------------------------------------------
# Workflows that MUST carry the policy. Declared here and found on disk (SPEC corollary b): an entry whose workflow vanished fails as stale, and a
# workflow that uses the composites without being in the list is judged by every rule below all the same.
EN_REQUIRED=(lego-aws-cicd lego-aws-environment-deploy)
# The only inputs whose name is about the guard: the COMMAND the package guard runs (a string). Declared here and found on disk (stale entry otherwise).
EN_KNOB_ALLOWED=(guardrails-command)
GUARD_COMPOSITE=.github/actions/package-guardrails/action.yml
GUARD_SCRIPT=scripts/package-guardrails.sh
# The environment the guard composite may hand to its script (the context every caller command gets, plus the data of the guard).
EN_GUARD_ENV=(SCRIPTS CMD ENVIRONMENT INSTALL_DIRS PACKAGE_MANAGER ROOT_KINDS PROJECT APP_ENV APP_STAGE STACK_SUFFIX AWS_REGION)
EN_POLICY_COMPOSITES_RE='/\.github/actions/(package-guardrails|nextep-packages-policy)@'

# jobs_with_policy <workflow json>: the job ids that use the guard or the policy composite (found on disk, never listed)
jobs_with_policy() {
  jq -r --arg re "$EN_POLICY_COMPOSITES_RE" '.jobs | to_entries[] | select([(.value.steps // [])[] | (.uses // "") | test($re)] | any) | .key' <<<"$1"
}
# step_indexes <json> <job> <composite>: the indexes of the steps that use that composite, one per line
step_indexes() {
  jq -r --arg j "$2" --arg c "/.github/actions/$3@" '(.jobs[$j].steps // []) | to_entries[] | select((.value.uses // "") | contains($c)) | .key' <<<"$1"
}

@test "EN-WIRE: every job that uses the package guard or the policy has both, once, in order (quality gate, guard, policy, evidence, end stamp), after !cancelled(), wired to the environment and to each other" {
  gate_require_tools yq jq
  gate_discover_lego_workflows EN-WIRE
  local workflows=("${GATE_SUBJECTS[@]}") wf json job g p q e s total=0 name has_job step
  GATE_VIOLATIONS=()
  for wf in "${workflows[@]}"; do
    json="$(gate_json "$wf")"
    has_job=0
    while IFS= read -r job; do
      [[ -n $job ]] || continue
      has_job=1
      total=$((total + 1))
      g="$(step_indexes "$json" "$job" package-guardrails)"
      p="$(step_indexes "$json" "$job" nextep-packages-policy)"
      if [[ "$(grep -c . <<<"$g")" != 1 || "$(grep -c . <<<"$p")" != 1 ]]; then
        gate_violation "$wf" "job '$job' must use the package-guardrails composite exactly once and the nextep-packages-policy composite exactly once (found $(grep -c . <<<"$g") and $(grep -c . <<<"$p"))"
        continue
      fi
      q="$(step_indexes "$json" "$job" quality-gate | head -n 1)"
      e="$(step_indexes "$json" "$job" nextep-packages-evidence | head -n 1)"
      s="$(jq -r --arg j "$job" '(.jobs[$j].steps // []) | map(.id // "") | index("stamp-end") // -1' <<<"$json")"
      [[ -n $q ]] || gate_violation "$wf" "job '$job' has the policy but no quality-gate step: the guard and the policy come after it"
      [[ -z $q ]] || ((q < g)) || gate_violation "$wf" "job '$job': the package guard must run AFTER the quality gate"
      ((g < p)) || gate_violation "$wf" "job '$job': the packages policy must run AFTER the package guard (it reads its result)"
      [[ -z $e ]] || ((p < e)) || gate_violation "$wf" "job '$job': the packages evidence must run AFTER the policy"
      ((s < 0 || p < s)) || gate_violation "$wf" "job '$job': the policy must run BEFORE the end stamp, which stays the last step (T9)"
      for step in "$g" "$p"; do
        jq -e --arg j "$job" --argjson i "$step" '(.jobs[$j].steps[$i].if // "") | (contains("!cancelled()") and (contains("always()") | not))' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': step #$step of the policy must carry 'if: \${{ !cancelled() }}' (it runs when an earlier step failed, and not when the run was cancelled)"
        jq -e --arg j "$job" --argjson i "$step" '.jobs[$j].steps[$i].with.environment == "${{ inputs.environment }}"' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': step #$step must receive 'environment: \${{ inputs.environment }}' (the environment decides the mode, and nothing else)"
        jq -e --arg j "$job" --argjson i "$step" '.jobs[$j].steps[$i].with["root-kinds"] == "${{ inputs.root-kinds }}"' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': step #$step must receive 'root-kinds: \${{ inputs.root-kinds }}'"
        jq -e --arg j "$job" --argjson i "$step" '.jobs[$j].steps[$i]["continue-on-error"] != true' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': step #$step sets continue-on-error: a warning is an exit code, never a masked failure (G-COE)"
      done
      jq -e --arg j "$job" --argjson i "$g" '(.jobs[$j].steps[$i].id // "") == "package-guardrails"' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job': the package guard step must have the id 'package-guardrails' (the policy and the evidence read its result)"
      jq -e --arg j "$job" --argjson i "$g" '.jobs[$j].steps[$i].with["guardrails-command"] == "${{ inputs.guardrails-command }}"' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job': the package guard must receive 'guardrails-command: \${{ inputs.guardrails-command }}'"
      jq -e --arg j "$job" --argjson i "$p" '.jobs[$j].steps[$i].with["guardrails-result"] == "${{ steps.package-guardrails.outputs.result }}"' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job': the policy must receive 'guardrails-result: \${{ steps.package-guardrails.outputs.result }}' (the real result, never the outcome nor a fixed text)"
      # the policy reads node_modules and the lockfiles: a setup-project step that only runs for lint or tests would leave it with nothing to read
      s="$(step_indexes "$json" "$job" setup-project | head -n 1)"
      if [[ -n $s ]]; then
        jq -e --arg j "$job" --argjson i "$s" '(.jobs[$j].steps[$i].if // "") | (. == "" or contains("inputs.root-kinds"))' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': the policy needs the project installed: the setup-project step has an 'if' that does not mention inputs.root-kinds, so a repository with no lint or test command would be read with nothing installed (a false PF-6)"
      fi
      s="$(jq -r --arg j "$job" '(.jobs[$j].steps // []) | map(.id // "") | index("stamp-end") // -1' <<<"$json")"
      if [[ -n $e ]]; then
        jq -e --arg j "$job" --argjson i "$e" '.jobs[$j].steps[$i].with.environment == "${{ inputs.environment }}"' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': the evidence step must receive 'environment: \${{ inputs.environment }}' (it names the mode of the policy)"
      fi
    done < <(jobs_with_policy "$json")
    if ((!has_job)); then
      name="$(basename "$wf" .yml)"
      [[ " ${EN_REQUIRED[*]} " != *" $name "* ]] || gate_violation "$wf" "must run the package guard and the packages policy in its gate job (it is in the EN_REQUIRED list of this gate)"
    fi
  done
  for name in "${EN_REQUIRED[@]}"; do
    [[ -f $GATES_ROOT/.github/workflows/$name.yml ]] || gate_violation ".github/workflows/$name.yml" "is in the EN_REQUIRED list of the gate but does not exist (stale entry)"
  done
  ((total > 0)) || gate_violation ".github/workflows" "no job runs the package guard or the packages policy (a gate that finds nothing proves nothing)"
  gate_finish EN-WIRE
}

@test "EN-NOKNOB: no input of any workflow or contract can lower, skip or switch off the policy (a name about enforce, packages-mode, guardrail, policy, skip, relax, warn, bypass, override or disable is a violation unless declared twice)" {
  gate_require_tools yq jq
  gate_discover EN-NOKNOB .github/workflows contracts -maxdepth 1 -type f '(' -name 'lego-*.yml' -o -name 'lego-*.contract.yml' ')'
  local f name seen=""
  local knob_re='(^|-)(enforce|enforcement|guardrail|guardrails|policy|skip|relax|warn|warning|bypass|override|disable|ignore|lenient|soft)(-|$)|(^|-)(packages|policy|guardrails|guardrail|enforce|enforcement|gate|strict)-mode(-|$)|(^|-)mode-(packages|policy)(-|$)'
  GATE_VIOLATIONS=()
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      [[ $name =~ $knob_re ]] || continue
      # the declared inputs: found on disk (they must exist, or the entry is stale) and held to their shape (a string with the default of the command)
      if [[ " ${EN_KNOB_ALLOWED[*]} " == *" $name "* ]]; then
        seen+=" $name"
        gate_json "$f" | jq -e --arg n "$name" '(if has("on") then .on.workflow_call.inputs[$n] else .inputs[$n] end) | (.type == "string" and .default == "make guardrails")' >/dev/null ||
          gate_violation "$f" "the input '$name' must be a string with the default \"make guardrails\": it is the COMMAND of the package guard, never a switch"
        continue
      fi
      gate_violation "$f" "declares the input '$name', whose name is about relaxing or configuring the policy: the policy is always on and the mode comes from the environment alone (the only declared input of this kind is in EN_KNOB_ALLOWED)"
    done < <(gate_json "$f" | jq -r 'if has("on") then (.on.workflow_call.inputs // {} | keys[]) else (.inputs // {} | keys[]) end')
  done
  for name in "${EN_KNOB_ALLOWED[@]}"; do
    [[ " $seen " == *" $name "* ]] || gate_violation "contracts" "the input '$name' is in the EN_KNOB_ALLOWED list of the gate but no workflow or contract declares it (stale entry)"
  done
  gate_finish EN-NOKNOB
}

@test "EN-COE: no step that runs the quality gate, the package guard or the policy, and no job that holds them, sets continue-on-error (the warning is an exit code)" {
  gate_require_tools yq jq
  gate_discover_lego_workflows EN-COE
  local wf json n=0 bad line
  GATE_VIOLATIONS=()
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    bad="$(jq -r '.jobs | to_entries[] | .key as $j
      | select([(.value.steps // [])[] | (.uses // "") | test("/\\.github/actions/(quality-gate|package-guardrails|nextep-packages-policy)@")] | any)
      | ($j + ":job:" + ((.value["continue-on-error"] // false) | tostring)),
        ((.value.steps // [])[] | select((.uses // "") | test("/\\.github/actions/(quality-gate|package-guardrails|nextep-packages-policy)@"))
          | ($j + ":step:" + ((.["continue-on-error"] // false) | tostring)))' <<<"$json")"
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      n=$((n + 1))
      [[ $line != *:true ]] || gate_violation "$wf" "job '${line%%:*}' sets continue-on-error on a gate, the package guard or the policy (found '$line')"
    done <<<"$bad"
  done
  ((n > 0)) || gate_violation ".github/workflows" "no job runs the quality gate, the package guard or the policy (a gate that finds nothing proves nothing)"
  gate_finish EN-COE
}

@test "EN-SAFE-GUARD: the package-guardrails composite and script hand over only the context of a caller command, no secret, no id-token, no other action, and have no network or install" {
  gate_require_tools yq jq
  gate_discover EN-SAFE-GUARD .github/actions/package-guardrails scripts/package-guardrails.sh -type f
  local key line lines
  GATE_VIOLATIONS=()
  if [[ -f $GATES_ROOT/$GUARD_COMPOSITE ]]; then
    while IFS= read -r key; do
      [[ " ${EN_GUARD_ENV[*]} " == *" $key "* ]] ||
        gate_violation "$GUARD_COMPOSITE" "hands the variable '$key' to the script: only ${EN_GUARD_ENV[*]} are allowed (no secret, no token)"
    done < <(gate_json "$GUARD_COMPOSITE" | jq -r '[.runs.steps[].env // {} | keys[]] | unique | .[]')
    lines="$(code_lines "$GUARD_COMPOSITE" | grep -nE 'secrets\.|github\.token|GITHUB_TOKEN|GH_TOKEN|id-token|continue-on-error|permissions:' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$GUARD_COMPOSITE" "code line ${line%%:*} mentions a secret, the token, id-token, permissions or continue-on-error: the guard needs none of them"
    done <<<"$lines"
    gate_json "$GUARD_COMPOSITE" | jq -e '[.runs.steps[] | select(has("uses"))] | length == 0' >/dev/null ||
      gate_violation "$GUARD_COMPOSITE" "uses another action (gate G11 forbids a composite inside a composite)"
    gate_json "$GUARD_COMPOSITE" | jq -e '[.runs.steps[].run // ""] | all(contains("package-guardrails.sh") or contains("derive-context.sh"))' >/dev/null ||
      gate_violation "$GUARD_COMPOSITE" "a step runs something other than scripts/package-guardrails.sh or scripts/derive-context.sh"
    gate_json "$GUARD_COMPOSITE" | jq -e '[.runs.steps[] | (.if // "") | contains("!cancelled()")] | all' >/dev/null ||
      gate_violation "$GUARD_COMPOSITE" "every step must carry 'if: \${{ !cancelled() }}'"
    gate_json "$GUARD_COMPOSITE" | jq -e '.outputs.result.value == "${{ steps.guard.outputs.result }}"' >/dev/null ||
      gate_violation "$GUARD_COMPOSITE" "must expose the output 'result' from the guard step (the real result, which the outcome of a step that only warns would hide)"
  fi
  if [[ -f $GATES_ROOT/$GUARD_SCRIPT ]]; then
    lines="$(code_lines "$GUARD_SCRIPT" | grep -nE '(^|[^A-Za-z0-9_.-])(curl|wget|gh|aws|az|npx|yarn|docker|ssh|nc|ncat)([^A-Za-z0-9_-]|$)|(npm|pnpm)[[:space:]]+(i|install|ci|add|dlx|exec|run|x|update|publish)([^A-Za-z]|$)|INTERNAL_DENYLIST|CODEARTIFACT|GITHUB_TOKEN|GH_TOKEN|secrets\.|printenv|declare -p|export -p|set -[a-z]*x|BASH_XTRACEFD' || true)"
    while IFS= read -r line; do
      [[ -n $line ]] && gate_violation "$GUARD_SCRIPT" "code line ${line%%:*} runs a network or install command, reads a secret, dumps the environment or traces the shell"
    done <<<"$lines"
    code_lines "$GUARD_SCRIPT" | grep -qE 'enforcement_mode "\$\{ENVIRONMENT-\}"' ||
      gate_violation "$GUARD_SCRIPT" "must take the mode from 'enforcement_mode \"\${ENVIRONMENT-}\"' (the single function)"
    code_lines "$GUARD_SCRIPT" | grep -qE '"\$here/run-command\.sh" guardrails' ||
      gate_violation "$GUARD_SCRIPT" "must run the command through run-command.sh (the one door of every caller command)"
    code_lines "$GUARD_SCRIPT" | grep -qE '^set -euo pipefail$' || gate_violation "$GUARD_SCRIPT" "must start with 'set -euo pipefail'"
  fi
  gate_finish EN-SAFE-GUARD
}
