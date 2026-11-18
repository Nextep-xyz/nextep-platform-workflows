#!/usr/bin/env bats
# scripts/ci/verify-release-tags.sh: the post-push verification of release.yml, against a REAL bare remote (no fakes):
# vX.Y.Z and vX must be the same commit on the remote, and a child of the released source commit.

bats_require_minimum_version 1.5.0
load 'helpers'

setup() {
  make_release_repo   # $RR, with v1.0.0 and v1 already cut (locally only)
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  rr_git remote add origin "$REMOTE"
  rr_commit "feat: Add a demo capability" scripts/run.sh
  SRC=$(rr_git rev-parse HEAD)
  cd "$RR"
}

# publish <X.Y.Z>: cut the release the way release.yml does and push the two tags.
publish() {
  rr_release "$1"
  rr_git push -q origin "refs/tags/v$1"
  rr_git push -q --force origin "refs/tags/v${1%%.*}"
}

verify() { run --separate-stderr bash "$SCRIPTS/ci/verify-release-tags.sh" "$@"; }

@test "a release published the way release.yml does it verifies, and the summary says what was compared" {
  publish 1.1.0
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  verify 1.1.0 "$SRC"
  [ "$status" -eq 0 ]
  [[ $output == *"verified: v1.1.0 and v1"* ]]
  grep -q 'parent of `v1.1.0`' "$GITHUB_STEP_SUMMARY"
}

@test "the alias pointing to another commit fails, naming both" {
  publish 1.1.0
  rr_git push -q --force origin "$(rr_git rev-parse "v1.0.0^{commit}"):refs/tags/v1"
  verify 1.1.0 "$SRC"
  [ "$status" -ne 0 ]
  [[ $stderr == *"do not point to the same commit"* ]]
}

@test "a release commit whose parent is not the released source fails" {
  publish 1.1.0
  verify 1.1.0 "$(rr_git rev-parse HEAD~1)"
  [ "$status" -ne 0 ]
  [[ $stderr == *"not the released source"* ]]
}

@test "a tag missing on the remote fails: the version first, then the alias" {
  rr_release 1.1.0                       # local only: nothing was pushed
  verify 1.1.0 "$SRC"
  [ "$status" -ne 0 ]
  [[ $stderr == *"v1.1.0 is not on 'origin'"* ]]
  rr_git push -q origin "refs/tags/v1.1.0"   # the version is there, the alias is not
  verify 1.1.0 "$SRC"
  [ "$status" -ne 0 ]
  [[ $stderr == *"the alias v1 is not on 'origin'"* ]]
}

@test "the remote is read, not the local clone: a lying local tag does not matter" {
  publish 1.1.0
  rr_git tag -f v1.1.0 "$(rr_git rev-parse HEAD)" >/dev/null
  verify 1.1.0 "$SRC"
  [ "$status" -eq 0 ]
}

@test "inputs are validated: a bad version, a short sha, an unreadable remote" {
  verify 1.1 "$SRC"
  [ "$status" -ne 0 ]
  verify 1.1.0 abc123
  [ "$status" -ne 0 ]
  RELEASE_REMOTE=nowhere verify 1.1.0 "$SRC"
  [ "$status" -ne 0 ]
}
