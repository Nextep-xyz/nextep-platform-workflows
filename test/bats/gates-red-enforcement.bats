#!/usr/bin/env bats
# The gates of the packages policy by environment (test/gates/enforcement.bats), verified IN RED (same method as gates-red.bats): each test builds a
# broken copy of the real tree under a temporary GATES_ROOT, runs the real gate against it and checks that it fails AND names the culprit file. The
# real tree is never touched.

load 'helpers'

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  export GATES_ROOT="$FX"
}

# en_fixture: the real scripts, composites and workflows, so each test breaks ONE thing in a tree that is otherwise the real one
en_fixture() {
  rm -rf "$FX"
  mkdir -p "$FX/.github" "$FX/contracts" "$FX/docs"
  cp -r "$REPO_ROOT/scripts" "$FX/scripts"
  cp -r "$REPO_ROOT/.github/actions" "$FX/.github/actions"
  cp -r "$REPO_ROOT/.github/workflows" "$FX/.github/workflows"
  cp "$REPO_ROOT"/contracts/*.yml "$FX/contracts/"
  cp "$REPO_ROOT/docs/exceptions.yml" "$FX/docs/exceptions.yml"
  cp "$REPO_ROOT/docs/runbook.md" "$FX/docs/runbook.md"
  cp "$REPO_ROOT/AGENTS.md" "$FX/AGENTS.md"
  POLICY="$FX/scripts/packages-policy.sh"
  POLICY_ACTION="$FX/.github/actions/nextep-packages-policy/action.yml"
  GUARD_ACTION="$FX/.github/actions/package-guardrails/action.yml"
  GUARD="$FX/scripts/package-guardrails.sh"
  CICD="$FX/.github/workflows/lego-aws-cicd.yml"
  GATEJOB='.jobs["quality-and-security-gate"].steps[]'
  RUNCMD="$FX/scripts/run-command.sh"
  LIB="$FX/scripts/lib/enforcement.sh"
}

red() { # red <gate file> <expected fragment>
  run bats "$REPO_ROOT/test/gates/$1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$2"* ]] || { echo "expected '$2' in:"; echo "$output"; return 1; }
}

@test "the EN fixture is clean: every EN gate passes on the real files" {
  en_fixture
  run bats "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "every EN gate fails with '0 subjects' or its 'no ... found' message on an empty tree instead of passing" {
  mkdir -p "$FX"
  run bats --filter '^EN-SINGLE:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 subjects discovered"* ]] || { echo "$output"; return 1; }
  run bats --filter '^EN-ENV:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 subjects discovered"* ]] || { echo "$output"; return 1; }
  run bats --filter '^EN-SAFE:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 subjects discovered"* ]] || { echo "$output"; return 1; }
}

# ---- EN-SINGLE ---------------------------------------------------------------------------------------------------------------------------------
@test "EN-SINGLE red: an environment compared in the policy script, a case pattern in run-command.sh and a literal mode in the composite are named" {
  en_fixture
  printf '\nif [[ ${ENVIRONMENT-} == prod ]]; then mode=warn; fi\n' >>"$POLICY"
  red enforcement.bats "scripts/packages-policy.sh: decides something from the name of an environment"
  [[ "$output" == *"scripts/packages-policy.sh: writes the mode as a literal"* ]]

  en_fixture
  printf '\ncase "${APP_ENV-}" in\n  prod) guardrails_mode=warn ;;\nesac\n' >>"$RUNCMD"
  red enforcement.bats "scripts/run-command.sh: decides something from the name of an environment"
  [[ "$output" == *"scripts/run-command.sh: writes the mode as a literal"* ]]

  en_fixture
  yq -i '.runs.steps[0].env.NEXTEP_GUARDRAILS_MODE = "warn"' "$POLICY_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-policy/action.yml: writes the mode as a literal"
}

@test "EN-SINGLE red: a new script that names the mode is a subject the moment it appears on disk, and a comparison with stg or dev is named too" {
  en_fixture
  printf '#!/usr/bin/env bash\n# uses enforcement_mode\nsource "$(dirname "$0")/lib/enforcement.sh"\nif [ "$1" = "stg" ]; then echo relaxed; fi\n[[ $1 != dev ]] && echo x\n' >"$FX/scripts/brand-new.sh"
  red enforcement.bats "scripts/brand-new.sh: decides something from the name of an environment"
}

@test "EN-SINGLE red: the function declared twice, or not at all, is named" {
  en_fixture
  printf '\nenforcement_mode() { printf warn; }\n' >>"$LIB"
  red enforcement.bats "scripts/lib/enforcement.sh: must declare 'enforcement_mode()' exactly once"
  en_fixture
  printf '# shellcheck shell=bash\n' >"$LIB"
  red enforcement.bats "scripts/lib/enforcement.sh: must declare 'enforcement_mode()' exactly once"
}

@test "EN-SINGLE: a comment that talks about prod, and the comparison of the mode itself, are not violations" {
  en_fixture
  printf '\n# in prod nothing blocks: this is a comment, not a decision\n[[ ${mode-} == enforce ]] && true\n' >>"$POLICY"
  run bats --filter '^EN-SINGLE:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ---- EN-ENV ------------------------------------------------------------------------------------------------------------------------------------
@test "EN-ENV red: a step that reaches run-command.sh without APP_ENV is named (a gate step, an infra step)" {
  en_fixture
  yq -i 'del(.runs.steps[] | select(.name == "Lint") | .env.APP_ENV)' "$FX/.github/actions/quality-gate/action.yml"
  red enforcement.bats ".github/actions/quality-gate/action.yml: step 'Lint' reaches run-command.sh without 'APP_ENV: \${{ inputs.environment }}'"

  en_fixture
  yq -i '(.runs.steps[] | select(.name == "Clean the synth cache") | .env.APP_ENV) = "dev"' "$FX/.github/actions/infra-deploy/action.yml"
  red enforcement.bats ".github/actions/infra-deploy/action.yml: step 'Clean the synth cache' reaches run-command.sh without"
}

@test "EN-ENV red: a step that reaches run-command.sh THROUGH another script (deploy-lambda.sh, infra-deploy.sh) is found on disk too" {
  en_fixture
  yq -i 'del(.runs.steps[] | select((.run // "") | test("deploy-lambda.sh")) | .env.APP_ENV)' "$FX/.github/actions/deploy-lambda/action.yml"
  red enforcement.bats ".github/actions/deploy-lambda/action.yml: step"

  en_fixture
  yq -i 'del(.runs.steps[] | select((.run // "") | test("infra-deploy.sh")) | .env.APP_ENV)' "$FX/.github/actions/infra-deploy/action.yml"
  red enforcement.bats ".github/actions/infra-deploy/action.yml: step"
}

@test "EN-ENV red: a brand-new composite with an environment input that runs run-command.sh without APP_ENV is named the moment it exists" {
  en_fixture
  mkdir -p "$FX/.github/actions/brand-new"
  cat >"$FX/.github/actions/brand-new/action.yml" <<'YAML'
name: brand-new
description: demo
inputs:
  environment: { description: env, required: true }
runs:
  using: composite
  steps:
    - name: Build
      shell: bash
      env:
        CMD: make build
      run: |
        "$SCRIPTS/run-command.sh" build
YAML
  red enforcement.bats ".github/actions/brand-new/action.yml: step 'Build' reaches run-command.sh without"
}

@test "EN-ENV: a composite WITHOUT an environment input (the package family) is not subject: its commands run with no APP_ENV, which is enforce" {
  en_fixture
  run bats --filter '^EN-ENV:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(yq -r '(.inputs // {}) | has("environment")' "$FX/.github/actions/run-project-command/action.yml")" = false ]
}

@test "EN-ENV red: a workflow that runs run-command.sh in a step without APP_ENV is named" {
  en_fixture
  cat >"$FX/.github/workflows/lego-direct.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      environment: { type: string, required: true }
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - run: scripts/run-command.sh lint
YAML
  red enforcement.bats ".github/workflows/lego-direct.yml: job 'gate' runs run-command.sh in a step without"
}

@test "EN-ENV red: run-command.sh that does not source the function, does not derive the mode from APP_ENV or does not export it is named" {
  en_fixture
  sed -i '/lib\/enforcement.sh/d' "$RUNCMD"
  red enforcement.bats "scripts/run-command.sh: must source lib/enforcement.sh"

  en_fixture
  sed -i 's/enforcement_mode "\${APP_ENV-}"/enforcement_mode dev/' "$RUNCMD"
  red enforcement.bats "scripts/run-command.sh: must derive the mode with"

  en_fixture
  sed -i 's/export NEXTEP_GUARDRAILS_MODE=/export OTHER_NAME=/' "$RUNCMD"
  red enforcement.bats "scripts/run-command.sh: must export NEXTEP_GUARDRAILS_MODE"
}

# ---- EN-SAFE -----------------------------------------------------------------------------------------------------------------------------------
@test "EN-SAFE red: a secret, a token, id-token, continue-on-error, a foreign variable and another action in the policy composite are named" {
  en_fixture
  yq -i '.runs.steps[0].env.MY_SECRET = "${{ secrets.X }}"' "$POLICY_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-policy/action.yml: hands the variable 'MY_SECRET' to the script"
  [[ "$output" == *"mentions a secret, the token, id-token, permissions or continue-on-error"* ]]

  en_fixture
  yq -i '.runs.steps[0]["continue-on-error"] = true' "$POLICY_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-policy/action.yml: code line"

  en_fixture
  yq -i '.runs.steps += [{"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"}]' "$POLICY_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-policy/action.yml: uses another action"

  en_fixture
  yq -i '.runs.steps[0].run = "echo skip"' "$POLICY_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-policy/action.yml: a step runs something other than scripts/packages-policy.sh"

  en_fixture
  yq -i 'del(.runs.steps[0].if)' "$POLICY_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-policy/action.yml: every step must carry"
}

@test "EN-SAFE red: a network call, an environment dump, a trace and a minimum read from a variable in the policy script are named" {
  en_fixture
  printf '\ncurl -s https://example.org/min >/dev/null\n' >>"$POLICY"
  red enforcement.bats "scripts/packages-policy.sh: code line"
  [[ "$output" == *"runs a network, install or package-manager command"* ]]

  en_fixture
  printf '\nprintenv >/tmp/x\nset -x\n' >>"$POLICY"
  red enforcement.bats "scripts/packages-policy.sh: code line"
  [[ "$output" == *"reads a secret, dumps the environment or traces the shell"* ]]

  en_fixture
  printf '\nmin="${MIN_VERSION:-0.0.1}"\n' >>"$POLICY"
  red enforcement.bats "reads a minimum or recommended version from a variable"
}

@test "EN-SAFE red: a policy that decides its own mode, or reads its own verdict, is named" {
  en_fixture
  sed -i 's/enforcement_mode "\${ENVIRONMENT-}"/echo enforce/' "$POLICY"
  red enforcement.bats "scripts/packages-policy.sh: must take the mode from 'enforcement_mode"

  en_fixture
  sed -i 's/packages-evidence.sh" findings/other.sh" findings/' "$POLICY"
  red enforcement.bats "scripts/packages-policy.sh: must take its verdict from 'packages-evidence.sh findings'"
}

@test "EN-SAFE red: a network call in a shared library is named" {
  en_fixture
  printf '\nwget https://example.org/x\n' >>"$FX/scripts/lib/semver.sh"
  red enforcement.bats "scripts/lib/semver.sh: code line"
}

# ---- F2: the wiring gates -----------------------------------------------------------------------------------------------------------------------
@test "the wiring gates (EN-WIRE, EN-NOKNOB, EN-COE, EN-SAFE-GUARD) fail with '0 subjects' on an empty tree instead of passing" {
  local g
  mkdir -p "$FX"
  for g in EN-WIRE EN-NOKNOB EN-COE EN-SAFE-GUARD; do
    run bats --filter "^$g:" "$REPO_ROOT/test/gates/enforcement.bats"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0 subjects discovered"* ]] || { echo "$g: $output"; return 1; }
  done
}

@test "EN-WIRE red: a gate job without the guard or without the policy, and a workflow of the required list that does not carry them, are named" {
  en_fixture
  yq -i 'del('"$GATEJOB"' | select(.name == "Packages policy"))' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate' must use the package-guardrails composite exactly once and the nextep-packages-policy composite exactly once (found 1 and 0)"

  en_fixture
  yq -i 'del('"$GATEJOB"' | select(.name == "Package guardrails"))' "$CICD"
  red enforcement.bats "found 0 and 1"

  en_fixture
  yq -i 'del('"$GATEJOB"' | select(.name == "Package guardrails" or .name == "Packages policy"))' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: must run the package guard and the packages policy in its gate job (it is in the EN_REQUIRED list of this gate)"
}

@test "EN-WIRE red: a wrong order, a missing !cancelled(), always(), a wrong environment, root-kinds, command or result wiring are named" {
  en_fixture
  yq -i '.jobs["quality-and-security-gate"].steps |= ([.[] | select(.name == "Packages policy")] + [.[] | select(.name != "Packages policy")])' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate': the packages policy must run AFTER the package guard"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages policy")).if = "${{ success() }}"' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate': step #"
  [[ "$output" == *"of the policy must carry 'if: \${{ !cancelled() }}'"* ]]

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Package guardrails")).if = "${{ always() && !cancelled() }}"' "$CICD"
  red enforcement.bats "of the policy must carry 'if: \${{ !cancelled() }}'"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages policy")).with.environment = "dev"' "$CICD"
  red enforcement.bats "must receive 'environment: \${{ inputs.environment }}' (the environment decides the mode, and nothing else)"

  en_fixture
  yq -i 'del(('"$GATEJOB"' | select(.name == "Packages policy")).with["root-kinds"])' "$CICD"
  red enforcement.bats "must receive 'root-kinds: \${{ inputs.root-kinds }}'"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Package guardrails")).with["guardrails-command"] = "make guardrails"' "$CICD"
  red enforcement.bats "the package guard must receive 'guardrails-command: \${{ inputs.guardrails-command }}'"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages policy")).with["guardrails-result"] = "${{ steps.package-guardrails.outcome }}"' "$CICD"
  red enforcement.bats "the policy must receive 'guardrails-result: \${{ steps.package-guardrails.outputs.result }}' (the real result, never the outcome nor a fixed text)"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Package guardrails")).id = "guard"' "$CICD"
  red enforcement.bats "the package guard step must have the id 'package-guardrails'"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages evidence")).with.environment = "prod"' "$CICD"
  red enforcement.bats "the evidence step must receive 'environment: \${{ inputs.environment }}'"
}

@test "EN-WIRE red: the policy after the evidence, and after the end stamp, are named" {
  en_fixture
  yq -i '.jobs["quality-and-security-gate"].steps |= ([.[] | select(.name != "Packages evidence")] + [.[] | select(.name == "Packages evidence")])' "$CICD"
  yq -i '.jobs["quality-and-security-gate"].steps |= ([.[] | select(.name != "Packages policy")] + [.[] | select(.name == "Packages policy")])' "$CICD"
  red enforcement.bats "the policy must run BEFORE the end stamp, which stays the last step (T9)"
}

@test "EN-NOKNOB red: an input that lowers, skips or switches off the policy is named in the workflow and in the contract; an unrelated input and the declared exception are not" {
  local name
  for name in packages-enforce packages-mode policy-mode skip-guardrails enforce-guardrails relax-policy guardrails-warn disable-policy bypass-policy; do
    en_fixture
    yq -i '.on.workflow_call.inputs["'"$name"'"] = {"type": "boolean", "default": false}' "$CICD"
    yq -i '.inputs["'"$name"'"] = {"type": "boolean", "default": false}' "$FX/contracts/lego-aws-cicd.contract.yml"
    red enforcement.bats ".github/workflows/lego-aws-cicd.yml: declares the input '$name', whose name is about relaxing or configuring the policy"
    [[ "$output" == *"contracts/lego-aws-cicd.contract.yml: declares the input '$name'"* ]] || { echo "$name: $output"; return 1; }
  done
  en_fixture
  yq -i '.on.workflow_call.inputs["db-ssl-mode"].default = "verify-full"' "$CICD"
  run bats --filter '^EN-NOKNOB:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -eq 0 ] || { echo "db-ssl-mode must not be flagged: $output"; return 1; }
}

@test "EN-NOKNOB red: the one declared input (guardrails-command) is held to be a string with the default of the command, and a stale entry of the list is named" {
  en_fixture
  yq -i '.on.workflow_call.inputs["guardrails-command"] = {"type": "boolean", "default": false}' "$CICD"
  red enforcement.bats ".github/workflows/lego-aws-cicd.yml: the input 'guardrails-command' must be a string with the default \"make guardrails\": it is the COMMAND of the package guard, never a switch"

  en_fixture
  yq -i '.inputs["guardrails-command"].default = ""' "$FX/contracts/lego-aws-cicd.contract.yml"
  red enforcement.bats "contracts/lego-aws-cicd.contract.yml: the input 'guardrails-command' must be a string with the default"

  en_fixture
  yq -i 'del(.on.workflow_call.inputs["guardrails-command"])' "$CICD"
  yq -i 'del(.inputs["guardrails-command"])' "$FX/contracts/lego-aws-cicd.contract.yml"
  yq -i 'del(.on.workflow_call.inputs["guardrails-command"])' "$FX/.github/workflows/lego-aws-environment-deploy.yml"
  yq -i 'del(.inputs["guardrails-command"])' "$FX/contracts/lego-aws-environment-deploy.contract.yml"
  red enforcement.bats "the input 'guardrails-command' is in the EN_KNOB_ALLOWED list of the gate but no workflow or contract declares it (stale entry)"
}

@test "EN-COE red: continue-on-error on the package guard, on the policy, on the quality gate or on the job that holds them is named" {
  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Package guardrails"))["continue-on-error"] = true' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate' sets continue-on-error on a gate, the package guard or the policy"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages policy"))["continue-on-error"] = true' "$CICD"
  red enforcement.bats "found 'quality-and-security-gate:step:true'"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Quality gate"))["continue-on-error"] = true' "$CICD"
  red enforcement.bats "found 'quality-and-security-gate:step:true'"

  en_fixture
  yq -i '.jobs["quality-and-security-gate"]["continue-on-error"] = true' "$CICD"
  red enforcement.bats "found 'quality-and-security-gate:job:true'"
}

@test "EN-SAFE-GUARD red: a secret, an id-token, another action, a foreign variable, a network call and a guard that decides its own mode are named" {
  en_fixture
  yq -i '.runs.steps[1].env.MY_TOKEN = "${{ secrets.X }}"' "$GUARD_ACTION"
  red enforcement.bats ".github/actions/package-guardrails/action.yml: hands the variable 'MY_TOKEN' to the script"

  en_fixture
  yq -i '.runs.steps += [{"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"}]' "$GUARD_ACTION"
  red enforcement.bats ".github/actions/package-guardrails/action.yml: uses another action"

  en_fixture
  yq -i '.runs.steps[1].run = "make guardrails"' "$GUARD_ACTION"
  red enforcement.bats ".github/actions/package-guardrails/action.yml: a step runs something other than scripts/package-guardrails.sh or scripts/derive-context.sh"

  en_fixture
  yq -i '.outputs.result.value = "${{ steps.guard.outcome }}"' "$GUARD_ACTION"
  red enforcement.bats ".github/actions/package-guardrails/action.yml: must expose the output 'result' from the guard step"

  en_fixture
  yq -i 'del(.runs.steps[1].if)' "$GUARD_ACTION"
  red enforcement.bats ".github/actions/package-guardrails/action.yml: every step must carry"

  en_fixture
  printf '\ncurl -s https://example.org/x >/dev/null\n' >>"$GUARD"
  red enforcement.bats "scripts/package-guardrails.sh: code line"

  en_fixture
  sed -i 's/enforcement_mode "\${ENVIRONMENT-}"/echo enforce/' "$GUARD"
  red enforcement.bats "scripts/package-guardrails.sh: must take the mode from 'enforcement_mode"

  en_fixture
  sed -i 's|"\$here/run-command.sh" guardrails|bash -c "$cmd"|' "$GUARD"
  red enforcement.bats "scripts/package-guardrails.sh: must run the command through run-command.sh"
}

@test "EN-SINGLE / EN-ENV red: the guard composite is a call site that is found on disk (it reaches run-command.sh through package-guardrails.sh)" {
  en_fixture
  yq -i 'del(.runs.steps[] | select(.id == "guard") | .env.APP_ENV)' "$GUARD_ACTION"
  red enforcement.bats ".github/actions/package-guardrails/action.yml: step 'Run the package guard' reaches run-command.sh without 'APP_ENV: \${{ inputs.environment }}'"

  en_fixture
  printf '\nif [[ ${ENVIRONMENT-} == prod ]]; then echo relaxed; fi\n' >>"$GUARD"
  red enforcement.bats "scripts/package-guardrails.sh: decides something from the name of an environment"
}

@test "PE-OUTCOME red: the evidence reads the OUTCOME of the package guard (it would say success when it only warned), or outputs.result of a step that has none" {
  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages evidence")).with.validations = "Quality gate (lint and tests)=${{ steps.quality-gate.outcome }}\nPackage guardrails=${{ steps.package-guardrails.outcome }}\n"' "$CICD"
  run bats --filter '^PE-OUTCOME:' "$REPO_ROOT/test/gates/packages-evidence.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"reads the outcome of the package-guardrails step, which succeeds when it only warns: read steps.package-guardrails.outputs.result"* ]] || { echo "$output"; return 1; }

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages evidence")).with.validations = "Quality gate (lint and tests)=${{ steps.quality-gate.outputs.result }}\nPackage guardrails=${{ steps.package-guardrails.outputs.result }}\n"' "$CICD"
  run bats --filter '^PE-OUTCOME:' "$REPO_ROOT/test/gates/packages-evidence.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"reads steps.quality-gate.outputs.result, which only a step that uses one of (package-guardrails) has"* ]] || { echo "$output"; return 1; }

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages evidence")).with.validations = "Quality gate (lint and tests)=${{ steps.quality-gate.outcome }}\n"' "$CICD"
  run bats --filter '^PE-OUTCOME:' "$REPO_ROOT/test/gates/packages-evidence.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the validation step 'package-guardrails' (package-guardrails) is not reported by the evidence step"* ]] || { echo "$output"; return 1; }
}

# ---- F3: lego-aws-environment-deploy carries the same wiring ---------------------------------------------------------------------------------------
@test "F3 red: environment-deploy without the guard and the policy is named by EN-WIRE, and without the evidence by PE-REQUIRED" {
  en_fixture
  ENVDEP="$FX/.github/workflows/lego-aws-environment-deploy.yml"
  yq -i 'del(.jobs["quality-and-security-gate"].steps[] | select(.name == "Package guardrails" or .name == "Packages policy"))' "$ENVDEP"
  red enforcement.bats "lego-aws-environment-deploy.yml: must run the package guard and the packages policy in its gate job (it is in the EN_REQUIRED list of this gate)"

  en_fixture
  yq -i 'del(.jobs["quality-and-security-gate"].steps[] | select(.name == "Packages evidence"))' "$ENVDEP"
  run bats --filter '^PE-REQUIRED:' "$REPO_ROOT/test/gates/packages-evidence.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lego-aws-environment-deploy.yml: must invoke the nextep-packages-evidence composite exactly once (found 0)"* ]] || { echo "$output"; return 1; }
}

@test "F3 red: environment-deploy that does not install the project for the policy, and a Quality gate without an id, are named" {
  en_fixture
  ENVDEP="$FX/.github/workflows/lego-aws-environment-deploy.yml"
  yq -i '(.jobs["quality-and-security-gate"].steps[] | select(.name == "Quality gate")) |= del(.id)' "$ENVDEP"
  run bats --filter '^PE-OUTCOME:' "$REPO_ROOT/test/gates/packages-evidence.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no id, so its outcome cannot be reported"* ]] || { echo "$output"; return 1; }

  en_fixture
  yq -i '(.jobs["quality-and-security-gate"].steps[] | select(.name == "Set up the project")).if = "${{ inputs.lint-command != '"''"' || inputs.test-command != '"''"' }}"' "$ENVDEP"
  red enforcement.bats "lego-aws-environment-deploy.yml: job 'quality-and-security-gate': the policy needs the project installed"
}

# ---- EN-OPTIN: the early opt-in check (PF-1) -----------------------------------------------------------------------------------------------------
@test "EN-OPTIN red: no opt-in step, one that runs after the install, with an 'if', with a foreign environment or root-kinds, in environment-deploy too, are named" {
  en_fixture
  yq -i 'del('"$GATEJOB"' | select(.name == "Packages opt-in"))' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate' must use the nextep-packages-optin composite exactly once (found 0)"

  en_fixture
  ENVDEP="$FX/.github/workflows/lego-aws-environment-deploy.yml"
  yq -i 'del(.jobs["quality-and-security-gate"].steps[] | select(.name == "Packages opt-in"))' "$ENVDEP"
  red enforcement.bats "lego-aws-environment-deploy.yml: job 'quality-and-security-gate' must use the nextep-packages-optin composite exactly once (found 0)"

  # moved after the install and the quality gate: it would fail only after paying for them
  en_fixture
  yq -i '(.jobs["quality-and-security-gate"].steps) as $s | .jobs["quality-and-security-gate"].steps = (($s | map(select(.name != "Packages opt-in"))) + ($s | map(select(.name == "Packages opt-in"))))' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate': the opt-in check must run BEFORE the setup-project step"
  [[ "$output" == *"must run BEFORE the quality-gate step"* ]] || { echo "$output"; return 1; }

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages opt-in")).if = "${{ inputs.root-kinds == '"''"' }}"' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate': the opt-in check has an 'if'"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages opt-in"))["continue-on-error"] = true' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate': the opt-in check sets continue-on-error"

  en_fixture
  yq -i '('"$GATEJOB"' | select(.name == "Packages opt-in")).with.environment = "prod"' "$CICD"
  yq -i '('"$GATEJOB"' | select(.name == "Packages opt-in")).with["root-kinds"] = "{}"' "$CICD"
  red enforcement.bats "lego-aws-cicd.yml: job 'quality-and-security-gate': the opt-in check must receive 'environment:"
  [[ "$output" == *"the opt-in check must receive 'root-kinds:"* ]] || { echo "$output"; return 1; }
}

@test "EN-OPTIN red: the composite that runs the full phase, hands over a foreign variable or runs something else is named; an empty tree is '0 subjects'" {
  en_fixture
  OPTIN_ACTION="$FX/.github/actions/nextep-packages-optin/action.yml"
  yq -i '.runs.steps[0].env.POLICY_PHASE = "full"' "$OPTIN_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-optin/action.yml: must hand POLICY_PHASE: optin to the script"

  en_fixture
  yq -i '.runs.steps[0].env.MY_SECRET = "${{ secrets.X }}"' "$OPTIN_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-optin/action.yml: hands the variable 'MY_SECRET' to the script"
  [[ "$output" == *"nextep-packages-optin/action.yml: code line"* ]] || { echo "$output"; return 1; }

  en_fixture
  yq -i '.runs.steps[0].run = "echo skip"' "$OPTIN_ACTION"
  red enforcement.bats ".github/actions/nextep-packages-optin/action.yml: a step runs something other than scripts/packages-policy.sh"

  en_fixture
  rm -rf "$FX/.github/actions/nextep-packages-optin"
  red enforcement.bats ".github/actions/nextep-packages-optin/action.yml: does not exist"

  rm -rf "$FX"
  mkdir -p "$FX"
  run bats --filter '^EN-OPTIN:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 subjects discovered"* ]] || { echo "$output"; return 1; }
}

# ---- F4: the docs say what the code does ----------------------------------------------------------------------------------------------------------
@test "EN-DOC red: a finding the policy can print that the runbook does not explain, a missing section 12, an AGENTS.md without the function and a TODO are named; no policy script is '0 subjects'" {
  en_fixture
  mkdir -p "$FX/docs"
  cp "$REPO_ROOT/docs/runbook.md" "$FX/docs/runbook.md"
  cp "$REPO_ROOT/AGENTS.md" "$FX/AGENTS.md"
  run bats --filter '^EN-DOC:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -eq 0 ] || { echo "the clean fixture must pass: $output"; return 1; }

  sed -i 's/\*\*PF-4\*\*/PF-4/g' "$FX/docs/runbook.md"
  run bats --filter '^EN-DOC:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"docs/runbook.md: section 12 does not explain the finding PF-4"* ]] || { echo "$output"; return 1; }

  cp "$REPO_ROOT/docs/runbook.md" "$FX/docs/runbook.md"
  sed -i 's/^## 12\. /## Twelve. /' "$FX/docs/runbook.md"
  run bats --filter '^EN-DOC:' "$REPO_ROOT/test/gates/enforcement.bats"
  [[ "$output" == *"docs/runbook.md: has no section '## 12.'"* ]] || { echo "$output"; return 1; }

  cp "$REPO_ROOT/docs/runbook.md" "$FX/docs/runbook.md"
  printf '\nTODO write this\n' >>"$FX/docs/runbook.md"
  sed -i 's/enforcement_mode/the_function/g' "$FX/AGENTS.md"
  run bats --filter '^EN-DOC:' "$REPO_ROOT/test/gates/enforcement.bats"
  [[ "$output" == *"AGENTS.md: does not name enforcement_mode"* && "$output" == *"docs/runbook.md: has a TODO"* ]] || { echo "$output"; return 1; }

  rm -rf "$FX"
  mkdir -p "$FX"
  run bats --filter '^EN-DOC:' "$REPO_ROOT/test/gates/enforcement.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 subjects discovered"* ]] || { echo "$output"; return 1; }
}
