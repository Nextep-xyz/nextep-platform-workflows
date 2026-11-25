#!/usr/bin/env bats
# The packages evidence block with ENVIRONMENT (docs/runbook.md section 12): it names the mode of the policy and shows a red policy axis as a blocker
# (enforce: dev, stg) or as a warning (warn: prod), and it reads the REAL result of the package guard (pass | fail | warn | missing | skipped) from
# `steps.<id>.outputs.result`. A failed validation (lint, tests) is red in every environment: the relaxation is for the packages policy only.
# Without ENVIRONMENT the block is exactly the one of before (K4, also covered by packages-evidence*.bats, which are not modified).
# Fictional data (example-org / shop). The step itself always exits 0: a report never fails the job.

load 'helpers'
load 'policy-helpers'

setup() {
  policy_setup
  good_repo
  export ACTION_REPOSITORY=example-org/platform ACTION_REF=v9.9.9
}

block() { # block <environment or ''> <guard result>
  export VALIDATIONS=$'Quality gate=success\nPackage guardrails='"$2"
  : >"$GITHUB_STEP_SUMMARY"
  ENVIRONMENT="$1" run "$P/packages-evidence.sh" run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "no ENVIRONMENT: no Mode row, and the verdict of the block is the one of before" {
  block '' pass
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  absent '| Mode |' "$GITHUB_STEP_SUMMARY"
}

@test "the Mode row names enforce in dev and stg and warn in prod, from the single function (an unknown environment is enforce)" {
  block dev pass
  summary | grep -qF '| Mode | `enforce` in `dev` (the policy blocks the job) |'
  block stg pass
  summary | grep -qF '| Mode | `enforce` in `stg` (the policy blocks the job) |'
  block prod pass
  summary | grep -qF '| Mode | `warn` in `prod` (the policy reports and never blocks the delivery) |'
  block Prod pass
  summary | grep -qF '| Mode | `enforce` in `Prod` (the policy blocks the job) |'
}

@test "a guard that passes is a tick, in every environment, and the block is VERIFIED" {
  local e
  for e in dev stg prod; do
    block "$e" pass
    summary | grep -q 'packages evidence: ✅ VERIFIED'
    summary | grep -qF '| `Package guardrails` | ✅ passed |'
  done
}

@test "a red guard (fail) blocks in dev and stg (❌ FAILED) and is a warning in prod (⚠️ NOT GREEN, not blocking), never a tick" {
  local e
  for e in dev stg; do
    block "$e" fail
    summary | grep -q 'packages evidence: ❌ FAILED'
    summary | grep -qF '| `Package guardrails` | ❌ FAILED |'
    absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  done
  block prod fail
  summary | grep -qF 'packages evidence: ⚠️ NOT GREEN (not blocking in prod)'
  summary | grep -qF '| `Package guardrails` | ⚠️ FAILED (not blocking in prod) |'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  absent '❌ FAILED' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::warning::packages evidence: at least one package or validation is not green"* ]]
}

@test "a guard that warned (result warn) is a warning in every environment, never a tick" {
  local e
  for e in dev prod; do
    block "$e" warn
    summary | grep -qF '| `Package guardrails` | ⚠️ failed, not blocking in this environment |'
    absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  done
}

@test "a missing guard command is red in dev and a warning in prod" {
  block dev missing
  summary | grep -qF '| `Package guardrails` | ❌ missing |'
  summary | grep -q 'packages evidence: ❌ FAILED'
  block prod missing
  summary | grep -qF '| `Package guardrails` | ⚠️ missing (not blocking in prod) |'
  summary | grep -qF 'packages evidence: ⚠️ NOT GREEN (not blocking in prod)'
}

@test "a policy axis that is red (a required package not declared) is ❌ in dev and ⚠️ NOT GREEN in prod; the rows keep their ❌ marks" {
  break_PF-3
  block dev pass
  summary | grep -q 'packages evidence: ❌ FAILED'
  block prod pass
  summary | grep -qF 'packages evidence: ⚠️ NOT GREEN (not blocking in prod)'
  summary | grep -qF '❌ required by kind iac and not declared'
}

@test "a validation that really failed (lint, tests) is ❌ FAILED in prod too: the relaxation is only for the packages policy" {
  export VALIDATIONS=$'Quality gate=failure\nPackage guardrails=pass'
  : >"$GITHUB_STEP_SUMMARY"
  ENVIRONMENT=prod run "$P/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `Quality gate` | ❌ FAILED |'
}

@test "a guard that was skipped (no IaC root) is reported as skipped, not as a pass" {
  rm -rf infra
  front_root .
  export ROOT_KINDS='{".":"frontend"}' INSTALL_DIRS='.'
  block dev skipped
  summary | grep -qF '| `Package guardrails` | ⏭️ did not run (skipped) |'
  absent '✅ passed' "$GITHUB_STEP_SUMMARY"
}

@test "E11: a hostile ENVIRONMENT is shown reduced to a safe alphabet and still enforces" {
  block $'prod\n::error::pwned|`x' pass
  ! grep -qE '^::error::pwned' "$GITHUB_STEP_SUMMARY"
  summary | grep -qF '| Mode | `enforce` in `prod???error??pwned??x`'
}
