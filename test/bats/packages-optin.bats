#!/usr/bin/env bats
# scripts/packages-policy.sh in the phase `optin` (POLICY_PHASE=optin): the early opt-in check of the packages policy (docs/runbook.md section 12.2).
# It runs BEFORE the install, the lint and the tests, and it evaluates PF-1 and nothing else: a repository that has not declared `root-kinds` fails in
# dev and stg in seconds and only warns in prod. Fictional data (example-org / shop).
#   O1  no root-kinds: dev and stg fail with ::error title=PF-1::, prod warns and exits 0 (the same function of the environment as the full policy)
#   O2  with root-kinds the check passes whatever else is wrong (PF-2..PF-9 and the guard belong to the full phase, which needs the install)
#   O3  it needs nothing installed: a repository with no node_modules and no lockfile is judged on the input and the files alone
#   O4  an unknown phase is an internal error: fail-closed in dev and stg, a warning in prod

load 'helpers'
load 'policy-helpers'

setup() { policy_setup; }

run_optin() { # run_optin <environment>
  ENVIRONMENT="$1" POLICY_PHASE=optin run "$P/packages-policy.sh"
}

@test "O1: without root-kinds dev and stg fail at once with PF-1 and the section 'Package opt-in'; prod warns and exits 0" {
  good_repo
  unset ROOT_KINDS
  local e
  for e in dev stg; do
    : >"$GITHUB_STEP_SUMMARY"
    run_optin "$e"
    [ "$status" -eq 1 ] || { echo "$e exited $status: $output"; return 1; }
    [[ "$output" == *"::error title=PF-1::"*"environment $e"*"has not opted in. Declare the kind of every root with the input 'root-kinds'"* ]] || { echo "$e: $output"; return 1; }
    summary | grep -qF "### Package opt-in ❌ blocking in $e (mode enforce)"
    summary | grep -qF "| PF-1 | ❌ blocks |"
  done
  : >"$GITHUB_STEP_SUMMARY"
  run_optin prod
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"::warning title=PF-1::"* && "$output" != *"::error"* ]]
  summary | grep -qF "### Package opt-in ⚠️ not blocking in prod (mode warn)"
}

@test "O1: an unknown, empty or mistyped environment blocks like dev (fail-closed), as in the full policy" {
  good_repo
  unset ROOT_KINDS
  local e
  for e in Prod production "" qa; do
    run_optin "$e"
    [ "$status" -eq 1 ] || { echo "environment '$e' exited $status: $output"; return 1; }
  done
}

@test "O1: the message of PF-1 is the one of the full policy: it lists what every kind requires and what the disk shows" {
  good_repo
  printf '{}\n' >infra/cdk.json
  unset ROOT_KINDS
  run_optin dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"What each kind requires: iac -> @nextep/cdk-guardrails; backend -> nothing defined yet; frontend -> nothing defined yet; platform -> nothing defined yet."* ]]
  [[ "$output" == *"Detected: root 'infra' has CDK files, declare it iac."* ]]
}

@test "O2: with root-kinds declared the check passes in every environment, even if the full policy would find PF-2..PF-8 and a red guard" {
  local id e
  for id in PF-2 PF-3 PF-4 PF-5 PF-6 PF-7 PF-8; do
    for e in dev stg prod; do
      rm -rf "$PROJ"/* "$PROJ"/.[!.]* 2>/dev/null || true
      good_repo
      "break_$id"
      : >"$GITHUB_STEP_SUMMARY"
      GUARDRAILS_RESULT=fail run_optin "$e"
      [ "$status" -eq 0 ] || { echo "$id in $e exited $status: $output"; return 1; }
      [[ "$output" != *"::error"* && "$output" != *"::warning"* ]] || { echo "$id in $e: $output"; return 1; }
      summary | grep -qF "### Package opt-in ✅ declared in $e"
    done
  done
}

@test "O3: it needs nothing installed: no node_modules and no lockfile, only the input and the files on disk" {
  mkdir -p app
  printf '{ "name": "web", "private": true }\n' >app/package.json
  ROOT_KINDS='{"app":"frontend"}' run_optin dev
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  unset ROOT_KINDS
  run_optin dev
  [ "$status" -eq 1 ]
}

@test "O4: an unknown phase is an internal error: it blocks in dev and stg and only warns in prod" {
  good_repo
  ENVIRONMENT=dev POLICY_PHASE=later run "$P/packages-policy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown POLICY_PHASE 'later' (expected full or optin)"* ]] || { echo "$output"; return 1; }
  ENVIRONMENT=prod POLICY_PHASE=later run "$P/packages-policy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning title=packages policy::"* ]]
}

@test "the full phase is unchanged: POLICY_PHASE=full and the default give the same verdict and the section 'Package policy'" {
  good_repo
  break_PF-3
  ENVIRONMENT=dev run "$P/packages-policy.sh"
  local default_status=$status default_out=$output
  ENVIRONMENT=dev POLICY_PHASE=full run "$P/packages-policy.sh"
  [ "$status" -eq "$default_status" ]
  [ "$output" = "$default_out" ]
  [[ "$output" == *"::error title=PF-3::"* ]]
  summary | grep -qF "### Package policy ❌ blocking in dev (mode enforce)"
}
