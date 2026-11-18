#!/usr/bin/env bats
# scripts/ci/require-green-ci.sh (guard RA9): the jobs that must be green are READ from the CI workflow, and the script waits for
# them, fails on anything but success, and fails if there is nothing to check. `gh` is a fake (fakes/gh). Fictional data only.

bats_require_minimum_version 1.5.0
load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log" && : >"$FAKE_LOG"
  export FAKE_GH_ROWS="$BATS_TEST_TMPDIR/rows"
  export GITHUB_REPOSITORY=example-org/example-repo
  export SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
  export GH_TOKEN=fake-token-Qx91Lm
  export CI_WAIT_SECONDS=1 CI_POLL_SECONDS=0.2
  export SELF_CI_FILE="$BATS_TEST_TMPDIR/self-ci.yml"
  cat >"$SELF_CI_FILE" <<'YAML'
name: ci
on: push
jobs:
  lint-job:
    name: lint
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
  unit-job:
    name: unit
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
  nameless:
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
YAML
}

guard() { run --separate-stderr bash "$SCRIPTS/ci/require-green-ci.sh"; }
rows() { # rows <n> <lines...>: fixture of the Nth call
  local n=$1
  shift
  printf '%s\n' "$@" >"$FAKE_GH_ROWS.$n"
}
T=$'\t'

@test "RA9: every required job green => pass; the names come from the workflow (jobs.*.name, or the key when there is no name)" {
  rows 1 "lint${T}completed${T}success" "unit${T}completed${T}success" "nameless${T}completed${T}success" "release${T}in_progress${T}"
  guard
  [ "$status" -eq 0 ]
  [[ $output == *"required jobs, read from self-ci.yml: lint unit nameless"* ]]
  [[ $output == *"CI is green on $SOURCE_SHA"* ]]
  grep -q "commits/$SOURCE_SHA/check-runs" "$FAKE_LOG"
}

@test "RA9: a job that finished in failure fails at once, naming it (no waiting)" {
  rows 1 "lint${T}completed${T}success" "unit${T}completed${T}failure" "nameless${T}in_progress${T}"
  CI_WAIT_SECONDS=600 CI_POLL_SECONDS=60 guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not green"* && $stderr == *"unit (failure)"* ]]
}

@test "RA9: cancelled, skipped and neutral are not success" {
  local c
  for c in cancelled skipped neutral timed_out; do
    rows 1 "lint${T}completed${T}success" "unit${T}completed${T}$c" "nameless${T}completed${T}success"
    guard
    [ "$status" -ne 0 ] || { echo "'$c' was accepted"; return 1; }
    [[ $stderr == *"unit ($c)"* ]]
  done
}

@test "RA9: pending that turns green on a later poll => pass" {
  rows 1 "lint${T}completed${T}success" "unit${T}in_progress${T}" "nameless${T}queued${T}"
  rows 2 "lint${T}completed${T}success" "unit${T}completed${T}success" "nameless${T}in_progress${T}"
  rows 3 "lint${T}completed${T}success" "unit${T}completed${T}success" "nameless${T}completed${T}success"
  CI_WAIT_SECONDS=30 guard
  [ "$status" -eq 0 ]
  [[ $output == *"waiting for: unit (running) nameless (running)"* ]]
  [ "$(cat "$FAKE_GH_ROWS.count")" = 3 ]
}

@test "RA9: pending forever => times out naming what it waited for" {
  rows 1 "lint${T}completed${T}success" "unit${T}in_progress${T}" "nameless${T}completed${T}success"
  guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"did not finish within 1s"* && $stderr == *"unit (running)"* ]]
}

@test "RA9: no check-runs at all (empty answer) => fails, it does not pass in green" {
  guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"lint (not reported yet)"* && $stderr == *"unit (not reported yet)"* ]]
}

@test "RA9: a required job that never shows up fails even if the others are green" {
  rows 1 "lint${T}completed${T}success" "nameless${T}completed${T}success"
  guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"unit (not reported yet)"* ]]
}

@test "RA9: a re-run leaves one failed and one green row for the same job: the failure counts" {
  rows 1 "lint${T}completed${T}failure" "lint${T}completed${T}success" "unit${T}completed${T}success" "nameless${T}completed${T}success"
  guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"lint (failure)"* ]]
}

@test "RA9: a CI workflow that declares no jobs is an error, not a silent pass" {
  printf 'name: ci\non: push\njobs: {}\n' >"$SELF_CI_FILE"
  rows 1 "lint${T}completed${T}success"
  guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"0 jobs discovered"* ]]
}

@test "RA9: an API failure fails the guard; the token and the raw answer are never printed" {
  FAKE_GH_RC=1 guard
  [ "$status" -ne 0 ]
  [[ $stderr == *"could not read the check-runs"* ]]
  [[ $output != *"$GH_TOKEN"* && $stderr != *"$GH_TOKEN"* ]]
  rows 1 "lint${T}completed${T}success" "unit${T}completed${T}success" "nameless${T}completed${T}success"
  guard
  [[ $output != *"$GH_TOKEN"* && $output != *"completed"* ]]
}

@test "RA9: inputs are validated (a short or missing sha, a missing workflow file, a non-numeric wait)" {
  SOURCE_SHA=abc123 guard
  [ "$status" -ne 0 ]
  unset SOURCE_SHA
  guard
  [ "$status" -ne 0 ]
  SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 SELF_CI_FILE=/nonexistent/self-ci.yml guard
  [ "$status" -ne 0 ]
  SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 CI_WAIT_SECONDS=soon guard
  [ "$status" -ne 0 ]
}

@test "RA9: against the real self-ci.yml of this repository the required names are the ones the workflow declares" {
  unset SELF_CI_FILE
  rows 1 "static-analysis${T}completed${T}success" "tests${T}completed${T}success" "secret-scan${T}completed${T}success"
  guard
  [ "$status" -eq 0 ]
  [[ $output == *"required jobs, read from self-ci.yml: static-analysis tests secret-scan"* ]]
}
