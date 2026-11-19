#!/usr/bin/env bats
# scripts/node-ci.sh with a `pnpm` fake (test/bats/fakes). Fictional data.

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  cd "$BATS_TEST_TMPDIR"
}

visible() { grep -v '^::add-mask::' <<<"$output" || true; }

@test "test: runs pnpm test; typecheck runs pnpm typecheck" {
  run "$SCRIPTS/node-ci.sh" test
  [ "$status" -eq 0 ]
  run "$SCRIPTS/node-ci.sh" typecheck
  [ "$status" -eq 0 ]
  grep -q '^pnpm test ' "$FAKE_LOG"
  grep -q '^pnpm typecheck ' "$FAKE_LOG"
}

@test "test: without the secret nothing is masked and pnpm test sees no denylist" {
  run "$SCRIPTS/node-ci.sh" test
  [ "$status" -eq 0 ]
  [[ "$output" != *"::add-mask::"* ]]
  grep -q 'denylist=absent' "$FAKE_LOG"
}

@test "test: every name of INTERNAL_DENYLIST (newline or comma separated) is masked BEFORE the tests run, and pnpm still sees the list" {
  INTERNAL_DENYLIST=$'acme-internal, secret-project\nother-name' GATE_FORK_PR=false run "$SCRIPTS/node-ci.sh" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::acme-internal"* && "$output" == *"::add-mask::secret-project"* && "$output" == *"::add-mask::other-name"* ]]
  grep -q 'denylist=present fork=false' "$FAKE_LOG"
}

@test "test: the names never show in the visible output, and the fake of the fork flag is passed through" {
  INTERNAL_DENYLIST="acme-internal" GATE_FORK_PR=true run "$SCRIPTS/node-ci.sh" test
  [ "$status" -eq 0 ]
  [[ "$(visible)" != *"acme-internal"* ]]
  absent 'acme-internal' "$FAKE_LOG"
  grep -q 'fork=true' "$FAKE_LOG"
}

@test "test and typecheck: a failing pnpm fails the step" {
  FAKE_PNPM_FAIL=test run "$SCRIPTS/node-ci.sh" test
  [ "$status" -eq 1 ]
  [[ "$output" == *"'pnpm test' failed"* ]]
  FAKE_PNPM_FAIL=typecheck run "$SCRIPTS/node-ci.sh" typecheck
  [ "$status" -eq 1 ]
}

@test "an unknown subcommand is refused" {
  run "$SCRIPTS/node-ci.sh" lint
  [ "$status" -eq 1 ]
}
