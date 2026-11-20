#!/usr/bin/env bats
# scripts/image-publish.sh (lego-aws-image-publish) with `aws` and `docker` fakes: validate (inputs and the version tag), build (the tag is the
# version, never latest, a tag that exists is not rebuilt) and digest (read from ECR, validated, written to the outputs and the summary).

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh-output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/gh-summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/services/api"
  : >"$REPO/Dockerfile"
  : >"$REPO/services/api/Dockerfile"
  cd "$REPO"
  # a valid call by default; a test overrides one thing
  export EVENT_NAME=push REF_TYPE=tag REF_NAME=v1.2.3
  ACCT="$(printf '%012d' 7)"
  ROLE="arn:aws:iam::${ACCT}:role/shop-image-publish"
  inputs
}

# inputs [key=value...]: INPUTS_JSON with the defaults of the contract and the overrides given
inputs() {
  local base
  base="$(jq -n --arg role "$ROLE" '{project: "shop", "ecr-repository": "shop-engine", "role-arn": $role, "aws-region": "us-east-2",
    dockerfile: "Dockerfile", "docker-context": ".", platform: "linux/amd64", "tag-prefix": "v"}')"
  local kv
  for kv in "$@"; do
    base="$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$base")"
  done
  export INPUTS_JSON="$base"
}

# ---- validate ----------------------------------------------------------------------------------------------------------

@test "validate: a valid call writes the version of the tag and prints nothing sensitive" {
  run "$SCRIPTS/image-publish.sh" validate
  [ "$status" -eq 0 ]
  grep -qx 'version=1.2.3' "$GITHUB_OUTPUT"
  [[ $output != *"$ROLE"* ]]
  [[ $output != *"$ACCT"* ]]
}

@test "validate: a tag prefix other than v works (engine-v1.4.0 -> 1.4.0)" {
  inputs tag-prefix=engine-v
  REF_NAME=engine-v1.4.0 run "$SCRIPTS/image-publish.sh" validate
  [ "$status" -eq 0 ]
  grep -qx 'version=1.4.0' "$GITHUB_OUTPUT"
}

@test "validate: only the push of a TAG is a release (a branch, a pull request and a manual run are refused)" {
  local combo
  for combo in "push branch" "pull_request branch" "workflow_dispatch branch" "pull_request tag"; do
    EVENT_NAME="${combo%% *}" REF_TYPE="${combo##* }" run "$SCRIPTS/image-publish.sh" validate
    [ "$status" -eq 1 ] || { echo "accepted: $combo"; return 1; }
    [[ $output == *"only on the push of a version tag"* ]]
  done
}

@test "validate: a tag that is not <prefix>X.Y.Z is refused naming the tag (v1.2, v01.2.3, v1.2.3-rc1, 1.2.3, a foreign prefix)" {
  local tag
  for tag in v1.2 v01.2.3 v1.2.3-rc1 1.2.3 release-1.2.3 v1.2.3.4; do
    REF_NAME="$tag" run "$SCRIPTS/image-publish.sh" validate
    [ "$status" -eq 1 ] || { echo "accepted: $tag"; return 1; }
    [[ $output == *"tag '$tag'"* ]] || { echo "did not name '$tag': $output"; return 1; }
  done
}

@test "validate: every bad input is listed at once, and a role that is not an ARN is refused WITHOUT echoing its value" {
  inputs project=Shop 'ecr-repository=shop-{env}' role-arn=NOT-AN-ARN-SECRET-LOOKING aws-region=mars platform=windows/amd64 dockerfile=/etc/passwd docker-context=../outside
  run "$SCRIPTS/image-publish.sh" validate
  [ "$status" -eq 1 ]
  [[ $output == *"input 'project'"* ]]
  [[ $output == *"input 'ecr-repository'"* ]]
  [[ $output == *"input 'role-arn'"* ]]
  [[ $output == *"input 'aws-region'"* ]]
  [[ $output == *"input 'platform'"* ]]
  [[ $output == *"input 'dockerfile' must be relative"* ]]
  [[ $output == *"input 'docker-context' must not contain '..'"* ]]
  [[ $output != *"NOT-AN-ARN-SECRET-LOOKING"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "validate: a Dockerfile or a context that does not exist fails before any role is assumed" {
  inputs dockerfile=services/missing/Dockerfile
  run "$SCRIPTS/image-publish.sh" validate
  [ "$status" -eq 1 ]
  [[ $output == *"dockerfile 'services/missing/Dockerfile' does not exist"* ]]
  inputs docker-context=nowhere
  run "$SCRIPTS/image-publish.sh" validate
  [ "$status" -eq 1 ]
  [[ $output == *"docker-context 'nowhere' does not exist"* ]]
  inputs dockerfile=services/api/Dockerfile docker-context=services/api
  run "$SCRIPTS/image-publish.sh" validate
  [ "$status" -eq 0 ]
}

# ---- build -------------------------------------------------------------------------------------------------------------

@test "build: the tag is the version, the platform is passed, and NOTHING called latest is built or pushed" {
  export FAKE_ECR_MISSING=1 VERSION=1.2.3 REGISTRY=reg.example.com
  inputs dockerfile=services/api/Dockerfile docker-context=services/api platform=linux/arm64
  run "$SCRIPTS/image-publish.sh" build
  [ "$status" -eq 0 ]
  grep -qx 'docker build --file services/api/Dockerfile --tag reg.example.com/shop-engine:1.2.3 --platform linux/arm64 services/api' "$FAKE_LOG"
  grep -qx 'docker push reg.example.com/shop-engine:1.2.3' "$FAKE_LOG"
  ! grep -q 'latest' "$FAKE_LOG"
}

@test "build: a tag that already exists in ECR is not rebuilt nor pushed (a re-run after a partial failure)" {
  export VERSION=1.2.3 REGISTRY=reg.example.com
  run "$SCRIPTS/image-publish.sh" build
  [ "$status" -eq 0 ]
  [[ $output == *"already exists in ECR"* ]]
  ! grep -q '^docker ' "$FAKE_LOG"
}

@test "build: an ECR error other than 'not found' fails and builds nothing" {
  export FAKE_ECR_ERROR=AccessDeniedException VERSION=1.2.3 REGISTRY=reg.example.com
  run "$SCRIPTS/image-publish.sh" build
  [ "$status" -eq 1 ]
  ! grep -q '^docker ' "$FAKE_LOG"
}

@test "build: a version that is not X.Y.Z, or no registry, is refused" {
  VERSION=1.2 REGISTRY=r run "$SCRIPTS/image-publish.sh" build
  [ "$status" -eq 1 ]
  VERSION=1.2.3 REGISTRY="" run "$SCRIPTS/image-publish.sh" build
  [ "$status" -eq 1 ]
  [[ $output == *"REGISTRY"* ]]
}

# ---- digest ------------------------------------------------------------------------------------------------------------

@test "digest: reads the digest with describe-images in JSON and writes version, image and digest to the outputs and the summary" {
  export VERSION=1.2.3 REGISTRY=reg.example.com
  export FAKE_ECR_DIGEST="sha256:$(printf 'cd%.0s' {1..32})"
  run "$SCRIPTS/image-publish.sh" digest
  [ "$status" -eq 0 ]
  grep -q 'aws ecr describe-images --region us-east-2 --repository-name shop-engine --image-ids imageTag=1.2.3 --output json' "$FAKE_LOG"
  grep -qx 'version=1.2.3' "$GITHUB_OUTPUT"
  grep -qx 'image=reg.example.com/shop-engine:1.2.3' "$GITHUB_OUTPUT"
  grep -qx "digest=$FAKE_ECR_DIGEST" "$GITHUB_OUTPUT"
  grep -q "$FAKE_ECR_DIGEST" "$GITHUB_STEP_SUMMARY"
  grep -q 'reg.example.com/shop-engine:1.2.3' "$GITHUB_STEP_SUMMARY"
}

@test "digest: a malformed digest, an ECR failure and an empty answer all fail and write no output" {
  export VERSION=1.2.3 REGISTRY=reg.example.com
  FAKE_ECR_DIGEST="sha256:short" run "$SCRIPTS/image-publish.sh" digest
  [ "$status" -eq 1 ]
  [[ $output == *"no valid digest"* ]]
  FAKE_ECR_DIGEST="" run "$SCRIPTS/image-publish.sh" digest
  [ "$status" -eq 1 ]
  FAKE_ECR_ERROR=AccessDeniedException run "$SCRIPTS/image-publish.sh" digest
  [ "$status" -eq 1 ]
  [[ $output == *"could not read"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "an unknown command fails" {
  run "$SCRIPTS/image-publish.sh" frobnicate
  [ "$status" -eq 1 ]
  [[ $output == *"unknown command"* ]]
}
