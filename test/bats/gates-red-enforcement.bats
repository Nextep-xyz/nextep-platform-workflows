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
  mkdir -p "$FX/.github" "$FX/contracts"
  cp -r "$REPO_ROOT/scripts" "$FX/scripts"
  cp -r "$REPO_ROOT/.github/actions" "$FX/.github/actions"
  cp -r "$REPO_ROOT/.github/workflows" "$FX/.github/workflows"
  cp "$REPO_ROOT/contracts/package-profiles.yml" "$FX/contracts/"
  POLICY="$FX/scripts/packages-policy.sh"
  POLICY_ACTION="$FX/.github/actions/nextep-packages-policy/action.yml"
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
