#!/usr/bin/env bats
# scripts/packages-policy.sh: the packages policy of a run. The SAME finding is a blocker in dev and stg and a warning in prod, and a hotfix to
# prod is never held back by it (docs/runbook.md section 12). Fictional data (example-org / shop). The scripts run from a copy of the platform whose
# catalog is controlled (policy-helpers.bash), so the tests do not depend on the editorial values of the real one.
#   E1  prod never blocks: every PF-1..PF-8 and a red guard are exit 0 with ::warning:: in prod
#   E2  dev and stg block: every PF-1..PF-8 is exit 1 with ::error:: naming the KIND and the PACKAGE it requires
#   E11 what comes from the repository is neutralised in annotations and summary      E16 PF-8/PF-9 cover every @nextep/* in use, required or not
#   E17 PF-9 never blocks; PF-8 blocks in dev/stg and warns in prod; an unparseable version is PF-8; an in-repo (workspace) package is skipped

load 'helpers'
load 'policy-helpers'

setup() { policy_setup; }

run_policy() { # run_policy <environment>
  ENVIRONMENT="$1" run "$P/packages-policy.sh"
}

# --- the table of findings is complete -----------------------------------------------------------------------------------------------------
@test "E1/E2: the table of findings of the tests has the eight blocking ids, and the policy has a message for exactly those plus PF-9" {
  [ "${#PF_BLOCKING_IDS[@]}" -eq 8 ]
  local from_script
  from_script="$(grep -oE '^    PF-[0-9]\)' "$P/packages-policy.sh" | tr -d ' )' | sort | tr '\n' ' ')"
  [ "$from_script" = "PF-1 PF-2 PF-3 PF-4 PF-5 PF-6 PF-7 PF-8 PF-9 " ] || { echo "the policy has messages for: $from_script"; return 1; }
  local id
  for id in "${PF_BLOCKING_IDS[@]}"; do declare -F "break_$id" >/dev/null || { echo "no fixture break_$id"; return 1; }; done
}

@test "the good repository has no finding in any environment: exit 0, no annotation, a passed section" {
  good_repo
  local e
  for e in dev stg prod; do
    : >"$GITHUB_STEP_SUMMARY"
    run_policy "$e"
    [ "$status" -eq 0 ] || { echo "$e: $output"; return 1; }
    [[ "$output" != *"::error"* && "$output" != *"::warning"* ]] || { echo "$e: $output"; return 1; }
    summary | grep -qF "### Package policy ✅ passed in $e"
  done
}

# --- E2: dev and stg block ------------------------------------------------------------------------------------------------------------------
@test "E2: in dev and stg each finding PF-1..PF-8 fails the step with an ::error:: that names the kind (iac) and the package it requires" {
  local id e line
  for id in "${PF_BLOCKING_IDS[@]}"; do
    for e in dev stg; do
      rm -rf "$PROJ"/* "$PROJ"/.[!.]* 2>/dev/null || true
      good_repo
      "break_$id"
      : >"$GITHUB_STEP_SUMMARY"
      run_policy "$e"
      [ "$status" -eq 1 ] || { echo "$id in $e exited $status: $output"; return 1; }
      line="$(grep -F "::error title=$id::" <<<"$output" | head -n 1)"
      [ -n "$line" ] || { echo "$id in $e: no ::error title=$id:: in: $output"; return 1; }
      [[ $line == *"environment $e"* ]] || { echo "$id/$e: the message does not name the environment: $line"; return 1; }
      [[ $line == *"iac"* && $line == *"$CDK_PKG"* ]] || { echo "$id/$e: the message does not name the kind and the package: $line"; return 1; }
      [[ "$output" != *"::warning title=$id::"* ]] || { echo "$id/$e: the same finding is also a warning: $output"; return 1; }
      summary | grep -qF "### Package policy ❌ blocking in $e (mode enforce)"
      summary | grep -qF "| $id | ❌ blocks |"
    done
  done
}

@test "E2: the message of PF-1 is generated from the profile: what every kind requires, and what the disk shows" {
  good_repo
  printf '{}\n' >infra/cdk.json
  unset ROOT_KINDS
  run_policy dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"this repository has not opted in. Declare the kind of every root with the input 'root-kinds'"* ]]
  [[ "$output" == *"What each kind requires: iac -> @nextep/cdk-guardrails; backend -> nothing defined yet; frontend -> nothing defined yet; platform -> nothing defined yet."* ]]
  [[ "$output" == *"Detected: root 'infra' has CDK files, declare it iac."* ]]
}

@test "E2: a requirement added to the profile shows up in the message of PF-1 without touching the script" {
  good_repo
  unset ROOT_KINDS
  yq -i '.kinds.backend.required = ["@nextep/gates"]' "$PLAT/contracts/package-profiles.yml"
  run_policy dev
  [[ "$output" == *"backend -> @nextep/gates; frontend -> nothing defined yet"* ]]
}

# --- E1: prod never blocks ------------------------------------------------------------------------------------------------------------------
@test "E1: in prod each finding PF-1..PF-8 is exit 0 with a ::warning:: (never ::error::) and the section says it does not block" {
  local id line
  for id in "${PF_BLOCKING_IDS[@]}"; do
    rm -rf "$PROJ"/* "$PROJ"/.[!.]* 2>/dev/null || true
    good_repo
    "break_$id"
    : >"$GITHUB_STEP_SUMMARY"
    run_policy prod
    [ "$status" -eq 0 ] || { echo "$id in prod exited $status: $output"; return 1; }
    line="$(grep -F "::warning title=$id::" <<<"$output" | head -n 1)"
    [ -n "$line" ] || { echo "$id in prod: no ::warning title=$id:: in: $output"; return 1; }
    [[ $line == *"environment prod"* && $line == *"iac"* && $line == *"$CDK_PKG"* ]] || { echo "$id/prod: $line"; return 1; }
    [[ "$output" != *"::error"* ]] || { echo "$id in prod printed an ::error::: $output"; return 1; }
    summary | grep -qF '### Package policy ⚠️ not blocking in prod (mode warn)'
    summary | grep -qF "| $id | ⚠️ warning |"
  done
}

@test "E1: a red guard (fail) is PF-5, a missing command is PF-7, a guard that did not run in a repository with an IaC root is PF-7; in prod all of them warn" {
  good_repo
  GUARDRAILS_RESULT=fail run_policy prod
  [ "$status" -eq 0 ] && [[ "$output" == *"::warning title=PF-5::"* ]]
  GUARDRAILS_RESULT=warn run_policy prod
  [ "$status" -eq 0 ] && [[ "$output" == *"::warning title=PF-5::"* ]]
  GUARDRAILS_RESULT=missing run_policy prod
  [ "$status" -eq 0 ] && [[ "$output" == *"::warning title=PF-7::"* ]]
  printf '{}\n' >infra/cdk.json
  GUARDRAILS_RESULT=skipped run_policy prod
  [ "$status" -eq 0 ] && [[ "$output" == *"::warning title=PF-7::"* ]]
  GUARDRAILS_RESULT='' run_policy prod
  [ "$status" -eq 0 ] && [[ "$output" == *"::warning title=PF-7::"* ]]
  GUARDRAILS_RESULT=whatever run_policy prod
  [ "$status" -eq 0 ] && [[ "$output" == *"::warning title=PF-5::"* ]]
  [[ "$output" == *"unknown result 'whatever'"* ]]
  GUARDRAILS_RESULT=whatever run_policy dev
  [ "$status" -eq 1 ] && [[ "$output" == *"::error title=PF-5::"* ]]
}

@test "a guard that is skipped in a repository WITHOUT an IaC root is not a finding (nothing to guard)" {
  front_root .
  export ROOT_KINDS='{".":"frontend"}' INSTALL_DIRS='.'
  local e
  for e in dev stg prod; do
    GUARDRAILS_RESULT=skipped run_policy "$e"
    [ "$status" -eq 0 ] || { echo "$e: $output"; return 1; }
    [[ "$output" != *"::error"* && "$output" != *"::warning"* ]]
  done
}

@test "E1: many findings together in prod are all warnings, one section lists them all, and the exit is still 0" {
  good_repo
  break_PF-3
  export GUARDRAILS_RESULT=missing
  rm -rf infra/node_modules
  run_policy prod
  [ "$status" -eq 0 ]
  [ "$(grep -c '^::warning title=' <<<"$output")" -ge 2 ]
  [ "$(grep -c '^| PF-' "$GITHUB_STEP_SUMMARY")" -ge 2 ]
}

# --- the environment is the only thing that decides ---------------------------------------------------------------------------------------------
@test "an unknown, empty or mistyped environment blocks like dev (fail-closed): Prod, production, an empty value, nothing" {
  good_repo
  break_PF-3
  local e
  for e in Prod production PROD "" qa "prod "; do
    run_policy "$e"
    [ "$status" -eq 1 ] || { echo "environment '$e' exited $status: $output"; return 1; }
  done
  run env -u ENVIRONMENT "$P/packages-policy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"environment unset"* ]]
}

@test "nothing a caller can set relaxes it: not NEXTEP_GUARDRAILS_MODE, not a mode or enforce variable, not an input in the environment" {
  good_repo
  break_PF-3
  NEXTEP_GUARDRAILS_MODE=warn run_policy dev
  [ "$status" -eq 1 ]
  PACKAGES_ENFORCE=false PACKAGES_MODE=warn ENFORCEMENT_MODE=warn run_policy stg
  [ "$status" -eq 1 ]
}

@test "the same repository gives the same findings whatever the environment: only the severity changes" {
  good_repo
  break_PF-3
  export GUARDRAILS_RESULT=missing
  local ids_dev ids_prod
  run_policy dev
  ids_dev="$(grep -oE '^::(error|warning) title=PF-[0-9]+' <<<"$output" | sed -E 's/^::[a-z]+ title=//' | sort | tr '\n' ' ')"
  run_policy prod
  ids_prod="$(grep -oE '^::(error|warning) title=PF-[0-9]+' <<<"$output" | sed -E 's/^::[a-z]+ title=//' | sort | tr '\n' ' ')"
  [ -n "$ids_dev" ]
  [ "$ids_dev" = "$ids_prod" ]
}

# --- E16 / E17: the catalog -----------------------------------------------------------------------------------------------------------------
@test "E17: PF-9 (below recommended, at or above the minimum) is a warning in dev, stg AND prod, and never blocks" {
  good_repo
  break_PF-9
  local e
  for e in dev stg prod; do
    : >"$GITHUB_STEP_SUMMARY"
    run_policy "$e"
    [ "$status" -eq 0 ] || { echo "$e exited $status: $output"; return 1; }
    [[ "$output" == *"::warning title=PF-9::"* && "$output" != *"::error"* ]] || { echo "$e: $output"; return 1; }
    [[ "$output" == *"$CDK_PKG 0.3.5 is below the recommended 0.4.0 (the minimum is 0.3.0)"* ]]
  done
  summary | grep -qF '### Package policy ⚠️ not blocking in prod'
  run_policy dev
  summary | grep -qF '### Package policy ⚠️ warnings in dev (mode enforce, nothing blocks)'
}

@test "E17: PF-8 (below the minimum) blocks in dev and stg and warns in prod, and says the version, the minimum and the recommended" {
  good_repo
  break_PF-8
  run_policy dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=PF-8::"*"$CDK_PKG 0.2.0 is below the minimum 0.3.0 (recommended 0.4.0)"* ]]
  run_policy stg
  [ "$status" -eq 1 ]
  run_policy prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=PF-8::"* ]]
}

@test "E17: a version that is not a plain X.Y.Z (a prerelease) is PF-8: fail-closed, it blocks in dev and warns in prod" {
  good_repo
  iac_root infra 0.4.0-dev.1
  run_policy dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=PF-8::"*"0.4.0-dev.1"*"not a plain X.Y.Z"* ]]
  run_policy prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=PF-8::"* ]]
}

@test "E17: an in-repo (workspace) package has no version to compare: it is skipped by the catalog" {
  good_repo
  mkdir -p libs
  printf '{ "name": "libs", "private": true, "dependencies": { "@nextep/ecs-private-service": "workspace:*" } }\n' >libs/package.json
  printf '%s' "$LOCK_EMPTY" >libs/pnpm-lock.yaml
  export ROOT_KINDS='{".":"frontend","infra":"iac","libs":"backend"}' INSTALL_DIRS='.,infra,libs'
  run_policy dev
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"ecs-private-service"* ]]
}

@test "E16: PF-8 and PF-9 cover every @nextep/* in use, also one that its kind does not require (a backend root, kind with required: [])" {
  good_repo
  pkg_root api @nextep/ecs-private-service 0.1.0
  export ROOT_KINDS='{".":"frontend","infra":"iac","api":"backend"}' INSTALL_DIRS='.,infra,api'
  run_policy dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=PF-8::"*"@nextep/ecs-private-service 0.1.0 is below the minimum 0.2.0"*"used by kind backend"* ]]
  pkg_root api @nextep/ecs-private-service 0.2.5
  run_policy dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=PF-9::"*"@nextep/ecs-private-service 0.2.5 is below the recommended 0.3.0"* ]]
}

@test "E16: a package that the catalog does not list is informational: no finding, whatever its version" {
  good_repo
  pkg_root api @nextep/brand-new 0.0.1
  export ROOT_KINDS='{".":"frontend","infra":"iac","api":"backend"}' INSTALL_DIRS='.,infra,api'
  run_policy dev
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *"brand-new"* ]]
}

@test "the catalog comes ONLY from the profile of the platform: an environment variable that names a minimum is not read" {
  good_repo
  break_PF-8
  MIN_VERSION=0.0.1 NEXTEP_MIN_VERSION=0.0.1 PACKAGES_MIN_VERSION=0.0.1 run_policy dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=PF-8::"* ]]
}

# --- the step never fails for a reason it cannot explain ----------------------------------------------------------------------------------------
@test "E1: an internal error (a malformed root-kinds) fails in dev naming the reason and only warns in prod" {
  good_repo
  export ROOT_KINDS='not json'
  run_policy dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=packages policy::"*"could not be evaluated"*"root-kinds"* ]]
  run_policy prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=packages policy::"*"nothing is blocked in this environment"* ]]
  [[ "$output" != *"::error"* ]]
}

@test "E1: a missing profile file is an internal error: blocks in dev, warns in prod" {
  good_repo
  rm "$PLAT/contracts/package-profiles.yml"
  run_policy dev
  [ "$status" -eq 1 ]
  run_policy prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=packages policy::"* ]]
}

@test "the policy writes its outputs (mode, findings, blocking) for the steps after it" {
  good_repo
  break_PF-3
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : >"$GITHUB_OUTPUT"
  run_policy dev
  grep -qx 'mode=enforce' "$GITHUB_OUTPUT"
  grep -qx 'findings=1' "$GITHUB_OUTPUT"
  grep -qx 'blocking=1' "$GITHUB_OUTPUT"
  : >"$GITHUB_OUTPUT"
  run_policy prod
  grep -qx 'mode=warn' "$GITHUB_OUTPUT"
  grep -qx 'blocking=0' "$GITHUB_OUTPUT"
}

# --- E11: what comes from the repository is neutralised -----------------------------------------------------------------------------------------
@test "E11: a root-kinds key with a backtick, a pipe or a %0A is rejected, and the error that names it carries none of them" {
  good_repo
  local e
  for e in dev prod; do
    ROOT_KINDS='{".":"frontend","infra`|x%0A":"iac"}' run_policy "$e"
    [[ "$output" != *'`'* && "$output" != *'|'* && "$output" != *'%0A'* ]] || { echo "$e: $output"; return 1; }
  done
  ROOT_KINDS='{".":"frontend","infra`|x%0A":"iac"}' run_policy dev
  [ "$status" -eq 1 ]
  ROOT_KINDS='{".":"frontend","infra`|x%0A":"iac"}' run_policy prod
  [ "$status" -eq 0 ]
}

@test "E11: a directory whose name carries a pipe, a backtick, a percent sign or a line break reaches the annotations and the summary neutralised" {
  good_repo
  mkdir -p 'evil|`x%0A' $'break\n::error::pwned'
  printf '{}\n' >'evil|`x%0A/cdk.json'
  printf '{}\n' >$'break\n::error::pwned/cdk.json'
  local e
  for e in dev prod; do
    : >"$GITHUB_STEP_SUMMARY"
    run_policy "$e"
    # no injected workflow command: no line starts with the text that came from a directory name
    ! grep -qE '^::error::pwned' <<<"$output"
    [[ "$output" != *'evil|'* && "$output" != *'%0A'* ]]
    [[ "$(grep -E '^::(error|warning)' <<<"$output")" != *'`'* ]]
    ! grep -qF '`|' "$GITHUB_STEP_SUMMARY"
    ! grep -qE '^::error::pwned' "$GITHUB_STEP_SUMMARY"
    # every finding row of the summary keeps its four columns (a pipe in a name did not split the row)
    while IFS= read -r row; do
      [ "$(grep -o '|' <<<"$row" | wc -l)" -eq 5 ] || { echo "row with a broken shape: $row"; return 1; }
    done < <(grep '^| PF-' "$GITHUB_STEP_SUMMARY")
  done
}

@test "E11: a guard result with a line break and a workflow command inside cannot inject one" {
  good_repo
  GUARDRAILS_RESULT=$'x\n::error::pwned' run_policy prod
  [ "$status" -eq 0 ]
  ! grep -qE '^::error::pwned' <<<"$output"
  GUARDRAILS_RESULT=$'x\n::error::pwned' run_policy dev
  [ "$status" -eq 1 ]
  ! grep -qE '^::error::pwned' <<<"$output"
}

@test "E11: an environment value with a line break is shown reduced, and still enforces" {
  good_repo
  break_PF-3
  ENVIRONMENT=$'prod\n::error::pwned' run "$P/packages-policy.sh"
  [ "$status" -eq 1 ]
  ! grep -qE '^::error::pwned' <<<"$output"
}

# --- acceptance of the wiring: a caller of the sandbox ---------------------------------------------------------------------------------------------
@test "a sandbox caller with environment dev and no root-kinds FAILS with the message of PF-1, and the same caller in prod only warns" {
  local caller="$REPO_ROOT/test/sandbox/callers/cicd-no-opt-in.yml" env_in kinds_in
  env_in="$(yq -r '.jobs.cicd.with.environment' "$caller")"
  kinds_in="$(yq -r '.jobs.cicd.with["root-kinds"] // ""' "$caller")"
  [ "$env_in" = dev ]
  [ -z "$kinds_in" ]
  good_repo
  unset ROOT_KINDS
  ROOT_KINDS="$kinds_in" run_policy "$env_in"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error title=PF-1::"*"has not opted in. Declare the kind of every root with the input 'root-kinds'"* ]]
  ROOT_KINDS="$kinds_in" run_policy prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=PF-1::"* ]]
}

# --- the rollback by image-tag in prod (environment-deploy) ----------------------------------------------------------------------------------------
@test "E1: a rollback by image-tag in prod is not held back: the gate job of environment-deploy only warns, whatever the policy finds, and the deploy job waits for that gate" {
  local wf="$REPO_ROOT/.github/workflows/lego-aws-environment-deploy.yml"
  # the shape: image-tag is an input, the gate job runs the guard and the policy with !cancelled() (never success()) and the deploy job needs the gate
  [ "$(yq -r '.on.workflow_call.inputs | has("image-tag")' "$wf")" = true ]
  [ "$(yq -r '.jobs["infra-deploy"].needs | contains(["quality-and-security-gate"])' "$wf")" = true ]
  [ "$(yq -r '[.jobs["quality-and-security-gate"].steps[] | select((.uses // "") | test("(package-guardrails|nextep-packages-policy)@")) | (.if == "${{ !cancelled() }}")] | all' "$wf")" = true ]
  # the worst case in prod: no opt-in, a red guard and a missing command together
  good_repo
  unset ROOT_KINDS
  printf '{}\n' >infra/cdk.json
  GUARDRAILS_RESULT=fail run_policy prod
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::warning title=PF-1::"* && "$output" == *"::warning title=PF-5::"* && "$output" != *"::error"* ]]
  GUARDRAILS_RESULT=missing run_policy prod
  [ "$status" -eq 0 ]
  # and the same findings in dev do block
  GUARDRAILS_RESULT=fail run_policy dev
  [ "$status" -eq 1 ]
}
