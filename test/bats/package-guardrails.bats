#!/usr/bin/env bats
# scripts/package-guardrails.sh: the package guard as a step of the platform. The command of the caller (guardrails-command) runs only when the
# repository has an IaC root, and its result is mapped BY MODE inside the script (never with continue-on-error): in dev and stg a red guard fails the
# step, in prod it warns and exits 0. The real result travels in the output `result`. Fictional data (example-org / shop).
#   E1  prod never blocks (rc != 0, a missing command, no command: exit 0 with ::warning::)     E2  dev and stg block
#   The step also hands NEXTEP_GUARDRAILS_MODE to the command (through run-command.sh), so the CLI itself honors the mode.

load 'helpers'
load 'policy-helpers'

setup() {
  policy_setup
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : >"$GITHUB_OUTPUT"
  SEEN="$BATS_TEST_TMPDIR/seen"
  good_repo
  export PROJECT=shop AWS_REGION=us-east-2
}

guard() { # guard <environment> <command>
  export ENVIRONMENT="$1" APP_ENV="$1" CMD="$2"
  : >"$GITHUB_OUTPUT"
  run "$P/package-guardrails.sh"
}
result() { sed -n 's/^result=//p' "$GITHUB_OUTPUT"; }

@test "pass: a guard that exits 0 is result=pass in every environment" {
  local e
  for e in dev stg prod; do
    guard "$e" 'true'
    [ "$status" -eq 0 ] || { echo "$e: $output"; return 1; }
    [ "$(result)" = pass ]
  done
}

@test "E2: in dev and stg a red guard fails the step with result=fail and an ::error:: of the platform (not the raw one of run-command)" {
  local e
  for e in dev stg; do
    guard "$e" 'echo violation >&2; exit 3'
    [ "$status" -eq 1 ] || { echo "$e: $output"; return 1; }
    [ "$(result)" = fail ]
    [[ "$output" == *"::error title=package-guardrails::"*"(exit 3)"* ]]
    [[ "$output" != *"::error::'guardrails' failed"* ]]
    [[ "$output" == *"violation"* ]]
  done
}

@test "E1: in prod a red guard is exit 0, result=warn, a ::warning:: and no ::error:: at all" {
  guard prod 'echo violation >&2; exit 3'
  [ "$status" -eq 0 ]
  [ "$(result)" = warn ]
  [[ "$output" == *"::warning title=package-guardrails::"*"not blocking in this environment"* ]]
  [[ "$output" != *"::error"* ]]
  [[ "$output" == *"violation"* ]]
}

@test "a missing command (make: no such target, command not found) is result=missing: it fails in dev and stg, it warns in prod" {
  local cmd
  for cmd in "echo \"make: *** No rule to make target 'guardrails'.  Stop.\" >&2; exit 2" 'definitely-not-a-command-xyz'; do
    guard dev "$cmd"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ "$(result)" = missing ]
    guard stg "$cmd"
    [ "$status" -eq 1 ]
    guard prod "$cmd"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(result)" = missing ]
    [[ "$output" == *"::warning title=package-guardrails::"* && "$output" != *"::error"* ]]
  done
}

@test "no command configured in a repository with an IaC root is result=missing: dev and stg fail, prod warns" {
  guard dev ''
  [ "$status" -eq 1 ]
  [ "$(result)" = missing ]
  [[ "$output" == *"no guardrails command is configured"* ]]
  guard prod ''
  [ "$status" -eq 0 ]
  [ "$(result)" = missing ]
  [[ "$output" == *"::warning title=package-guardrails::"* ]]
}

@test "without an IaC root the guard is skipped in every environment and the command is not even run" {
  local e
  rm -rf infra
  front_root .
  export ROOT_KINDS='{".":"frontend"}' INSTALL_DIRS='.'
  for e in dev stg prod; do
    rm -f "$SEEN"
    guard "$e" "touch $SEEN; exit 9"
    [ "$status" -eq 0 ] || { echo "$e: $output"; return 1; }
    [ "$(result)" = skipped ]
    [ ! -e "$SEEN" ]
  done
}

@test "a repository whose CDK files sit in a root not declared iac still has the guard run (the IaC root is detected on disk)" {
  printf '{}\n' >infra/cdk.json
  export ROOT_KINDS='{".":"frontend","infra":"frontend"}'
  guard dev "touch $SEEN"
  [ "$status" -eq 0 ]
  [ -e "$SEEN" ]
  [ "$(result)" = pass ]
}

@test "the command sees the mode of the environment: enforce in dev and stg, warn in prod (NEXTEP_GUARDRAILS_MODE, set by run-command.sh)" {
  local e
  for e in dev stg prod; do
    guard "$e" "printf %s \"\$NEXTEP_GUARDRAILS_MODE\" >$SEEN"
    [ "$status" -eq 0 ]
    if [ "$e" = prod ]; then [ "$(cat "$SEEN")" = warn ]; else [ "$(cat "$SEEN")" = enforce ]; fi
  done
}

@test "an unknown or empty environment is enforce: a red guard fails" {
  local e
  for e in Prod production ''; do
    guard "$e" 'exit 3'
    [ "$status" -eq 1 ] || { echo "environment '$e': $output"; return 1; }
    [ "$(result)" = fail ]
  done
}

@test "the command does not get the CMD variable nor a way to pre-set the mode, and it still runs in the repository root" {
  guard prod "printf '%s|%s' \"\${CMD-unset}\" \"\$(basename \"\$PWD\")\" >$SEEN"
  [ "$status" -eq 0 ]
  [ "$(cat "$SEEN")" = "unset|proj" ]
}

@test "a malformed root-kinds does not decide anything here: result=skipped with a warning (the policy step reports the real error)" {
  export ROOT_KINDS='not json'
  guard dev 'exit 3'
  [ "$status" -eq 0 ]
  [ "$(result)" = skipped ]
  [[ "$output" == *"::warning title=package-guardrails::"*"could not be determined"* ]]
}

@test "the policy and the guard agree: the result the guard writes is what the policy turns into PF-5 and PF-7 (and a pass is no finding)" {
  local e res
  for e in dev prod; do
    guard "$e" 'exit 3'
    res="$(result)"
    GUARDRAILS_RESULT="$res" ENVIRONMENT="$e" run "$P/packages-policy.sh"
    [[ "$output" == *"title=PF-5::"* ]]
    guard "$e" ''
    res="$(result)"
    GUARDRAILS_RESULT="$res" ENVIRONMENT="$e" run "$P/packages-policy.sh"
    [[ "$output" == *"title=PF-7::"* ]]
    guard "$e" 'true'
    res="$(result)"
    GUARDRAILS_RESULT="$res" ENVIRONMENT="$e" run "$P/packages-policy.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"title=PF-"* ]]
  done
}
