#!/usr/bin/env bats
# Two bugs that every unit test missed because the tests ran WITHOUT $GITHUB_OUTPUT (Actions always sets it):
#   1. `stage="$(derive-context.sh | sed ...)"` captures nothing inside Actions (the script writes to $GITHUB_OUTPUT),
#      so the stage, and every template with {stage}, came out empty.
#   2. `echo "name=$(resolve-template.sh ...)" >>"$GITHUB_OUTPUT"` hides the failure of the substitution (set -e looks
#      at the exit status of echo), so the step stays green with an empty output and the next step fails with a
#      misleading message.

load 'lib/gates'

@test "derive-context.sh --print gives the bare stage on stdout even when GITHUB_OUTPUT is set" {
  local out="$BATS_TEST_TMPDIR/gh-output" got
  : >"$out"
  got="$(cd "$GATES_ROOT" && GITHUB_OUTPUT="$out" PROJECT=shop ENVIRONMENT=prod scripts/derive-context.sh --print)"
  [ "$got" = "Prod" ] || gate_fail "expected 'Prod' on stdout, got '$got'"
  [ ! -s "$out" ] || gate_fail "--print must not write to GITHUB_OUTPUT (it would duplicate the 'stage' key)"
}

@test "no composite captures derive-context.sh through a pipe (it needs --print)" {
  gate_discover G-STAGE .github/actions -type f -name action.yml
  local f n
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r n; do
      gate_violation "$f" "line $n captures derive-context.sh from stdout without --print: empty inside Actions"
    done < <(grep -nE '\$\(.*derive-context\.sh[^)]*\)' "$GATES_ROOT/$f" | grep -v -- '--print' | cut -d: -f1)
  done
  gate_finish G-STAGE
}

@test "no composite writes a command substitution straight into an echo (the failure is masked)" {
  gate_discover G-MASKED .github -type f -name '*.yml'
  local f n
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r n; do
      gate_violation "$f" "line $n: echo \"key=\$(cmd)\" masks the failure of cmd; assign to a variable first"
    done < <(grep -nE 'echo +"[A-Za-z0-9_-]+=\$\(' "$GATES_ROOT/$f" | cut -d: -f1)
  done
  gate_finish G-MASKED
}
