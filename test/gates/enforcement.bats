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
# The knob gate (EN-NOKNOB: no input that lowers the policy) arrives with the wiring of the workflows.

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
