#!/usr/bin/env bats
# derive-context.sh — the stage must reach stdout EVEN when GITHUB_OUTPUT is set (it always is inside a step).
# Regression of v1.0.0: the script wrote to the output file, the composites captured stdout with $(...) and got
# nothing, so every `{stage}` placeholder failed with "has no value" in the first real run.

load 'helpers'

setup() {
  export PROJECT=shop
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  : >"$GITHUB_OUTPUT"
}

@test "the stage is printed to stdout and a captured call gets it, with GITHUB_OUTPUT set" {
  ENVIRONMENT=prod
  export ENVIRONMENT
  stage="$("$SCRIPTS/derive-context.sh" | sed -n 's/^stage=//p')"
  [ "$stage" = "Prod" ]
}

@test "it never writes to GITHUB_OUTPUT itself (callers append it explicitly when they need it there)" {
  ENVIRONMENT=dev
  export ENVIRONMENT
  run "$SCRIPTS/derive-context.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "stage=Dev" ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "the append form used by the other composites still lands in the output file" {
  ENVIRONMENT=stg
  export ENVIRONMENT
  "$SCRIPTS/derive-context.sh" >>"$GITHUB_OUTPUT"
  [ "$(cat "$GITHUB_OUTPUT")" = "stage=Stg" ]
}

@test "an environment other than dev, stg or prod fails naming it" {
  ENVIRONMENT=qa
  export ENVIRONMENT
  run "$SCRIPTS/derive-context.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"got 'qa'"* ]]
}
