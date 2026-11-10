#!/usr/bin/env bats
# infra-deploy.sh: IMAGE_TAG pinned only in the configured environments (P-EN-08).

load 'helpers'

setup() {
  export OUT="$BATS_TEST_TMPDIR/out"
  export PROJECT=shop AWS_REGION=us-east-2 APP_ENV=dev APP_STAGE=Dev STACK_SUFFIX=Dev
  export INFRA_DEPLOY_COMMAND='env >"$OUT"'
}

@test "dev: the image tag is not pinned" {
  export ENVIRONMENT=dev DEPLOY_IMAGE_TAG=abc123
  run "$SCRIPTS/infra-deploy.sh"
  [ "$status" -eq 0 ]
  ! grep -q '^IMAGE_TAG=' "$OUT"
}

@test "stg and prod: IMAGE_TAG is pinned to the deployed tag" {
  local e
  for e in stg prod; do
    export ENVIRONMENT=$e DEPLOY_IMAGE_TAG=abc123
    run "$SCRIPTS/infra-deploy.sh"
    [ "$status" -eq 0 ]
    grep -qx 'IMAGE_TAG=abc123' "$OUT"
  done
}

@test "pin list is configurable and the control variables never reach the command" {
  export ENVIRONMENT=dev DEPLOY_IMAGE_TAG=abc123 PIN_IMAGE_TAG_ENVIRONMENTS=dev,prod
  run "$SCRIPTS/infra-deploy.sh"
  [ "$status" -eq 0 ]
  grep -qx 'IMAGE_TAG=abc123' "$OUT"
  ! grep -q '^INFRA_DEPLOY_COMMAND=\|^PIN_IMAGE_TAG_ENVIRONMENTS=\|^DEPLOY_IMAGE_TAG=\|^CMD=' "$OUT"
  grep -qx 'PROJECT=shop' "$OUT"
}

@test "an empty tag (lambda) pins nothing even in prod" {
  export ENVIRONMENT=prod DEPLOY_IMAGE_TAG=""
  run "$SCRIPTS/infra-deploy.sh"
  [ "$status" -eq 0 ]
  ! grep -q '^IMAGE_TAG=' "$OUT"
}

@test "a failing infra command fails the job" {
  export ENVIRONMENT=dev INFRA_DEPLOY_COMMAND='exit 4'
  run "$SCRIPTS/infra-deploy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'infra deploy' failed (exit 4)"* ]]
}
