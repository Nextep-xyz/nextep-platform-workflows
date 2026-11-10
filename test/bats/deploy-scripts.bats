#!/usr/bin/env bats
# Scripts of the quick deploy: run-command, check-required, fetch-deploy-env / deploy-lambda, ECS scripts, validate-inputs JSON path.

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  export OUT="$BATS_TEST_TMPDIR/out" ORDER="$BATS_TEST_TMPDIR/order"
  : >"$ORDER"
  export AWS_REGION=us-east-2 PROJECT=shop ENVIRONMENT=dev APP_ENV=dev APP_STAGE=Dev STACK_SUFFIX=Dev
}

# ---- run-command -------------------------------------------------------------------------------------------------------

@test "run-command: an empty command is skipped, a failing one fails naming its label, CMD is not leaked to the command" {
  CMD="" run "$SCRIPTS/run-command.sh" lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped 'lint'"* ]]
  CMD="exit 3" run "$SCRIPTS/run-command.sh" lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"'lint' failed (exit 3)"* ]]
  CMD='env >"$OUT"' run "$SCRIPTS/run-command.sh" test
  [ "$status" -eq 0 ]
  ! grep -q '^CMD=' "$OUT"
}

# ---- validate-inputs JSON path -------------------------------------------------------------------------------------------

@test "validate-inputs: the composite hands the inputs as JSON (toJSON(inputs)) and the same rules apply" {
  export EVENT_NAME=push REF_NAME=develop
  export INPUTS_JSON='{"project":"shop","environment":"dev","compute":"lambda","package-manager":"pnpm","db-ssl-mode":"verify-full","db-port":5432,"migration-timeout-minutes":20,"run-deploy":true,"deploy-command":"pnpm run deploy","db-url-template":"postgresql://{user}@{host}","ecs-deploy-mode":"force-new-deployment","node-version":"22","branch-map":""}'
  run "$SCRIPTS/validate-inputs.sh" cicd
  [ "$status" -eq 0 ]
  export INPUTS_JSON='{"project":"shop","environment":"dev","compute":"lambda","package-manager":"pnpm","db-ssl-mode":"disable","db-port":5432,"migration-timeout-minutes":20,"run-deploy":true,"deploy-command":"x","ecs-deploy-mode":"force-new-deployment"}'
  run "$SCRIPTS/validate-inputs.sh" cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'db-ssl-mode'"* ]]
}

# ---- check-required ----------------------------------------------------------------------------------------------------

@test "check-required: lists EVERYTHING that is missing, not only the first" {
  export REQUIRED_SSM_PARAMS='["/{project}/api/{stage}/a","/{project}/api/{stage}/b","/{project}/api/{stage}/ok"]'
  export REQUIRED_SECRETS='["{project}/{env}/s1","{project}/{env}/s2"]'
  export FAKE_MISSING="/shop/api/Dev/a /shop/api/Dev/b shop/dev/s2"
  run "$SCRIPTS/check-required.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSM parameter /shop/api/Dev/a"* ]]
  [[ "$output" == *"SSM parameter /shop/api/Dev/b"* ]]
  [[ "$output" == *"secret shop/dev/s2"* ]]
  [[ "$output" == *"3 required runtime item(s) are missing"* ]]
  [[ "$output" != *"ssm/api/Dev/ok"* ]]
}

@test "check-required: passes when everything exists" {
  export REQUIRED_SSM_PARAMS='["/{project}/api/{stage}/cluster"]' REQUIRED_SECRETS='["{project}/{env}/s1"]'
  run "$SCRIPTS/check-required.sh"
  [ "$status" -eq 0 ]
}

# ---- deploy-lambda -----------------------------------------------------------------------------------------------------

lambda_env() {
  export DEPLOY_COMMAND='echo deploy >>"$ORDER"' BUILD_COMMAND='echo build >>"$ORDER"' HOTSWAP_COMMAND="" HOTSWAP_ENVIRONMENTS=dev
  export DEPLOY_ENV_SSM='{}' DEPLOY_ENV_SECRETS='{}'
}

@test "deploy-lambda: build then the full deploy when there is no hotswap command" {
  lambda_env
  run "$SCRIPTS/deploy-lambda.sh"
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$ORDER")" = "build,deploy" ]
}

@test "deploy-lambda: hotswap only in hotswap-environments (dev yes, prod no)" {
  lambda_env
  export HOTSWAP_COMMAND='echo hotswap >>"$ORDER"'
  run "$SCRIPTS/deploy-lambda.sh"
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$ORDER")" = "build,hotswap" ]
  : >"$ORDER"
  export ENVIRONMENT=prod APP_ENV=prod APP_STAGE=Prod
  run "$SCRIPTS/deploy-lambda.sh"
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$ORDER")" = "build,deploy" ]
}

@test "deploy-lambda: the runtime variables reach ONLY the deploy command, masked first, never printed" {
  lambda_env
  export FAKE_SSM_VALUE='ssm-secret-value' FAKE_SECRET_JSON='{"apiKey":"sk-live-123"}'
  export DEPLOY_ENV_SSM='{"UPSTREAM_URL":"/{project}/ssm-values/{stage}/url"}' DEPLOY_ENV_SECRETS='{"API_KEY":"{project}/{env}/keys#apiKey"}'
  export BUILD_COMMAND='env >"$OUT.build"' DEPLOY_COMMAND='env >"$OUT.deploy"'
  run "$SCRIPTS/deploy-lambda.sh"
  [ "$status" -eq 0 ]
  grep -qx 'UPSTREAM_URL=ssm-secret-value' "$OUT.deploy"
  grep -qx 'API_KEY=sk-live-123' "$OUT.deploy"
  ! grep -q 'UPSTREAM_URL\|API_KEY' "$OUT.build"
  ! grep -q 'DEPLOY_ENV_SSM\|DEPLOY_ENV_SECRETS' "$OUT.deploy"
  mapfile -t lines <<<"$output"
  for l in "${lines[@]}"; do
    [[ $l == "::add-mask::"* ]] || [[ $l != *"sk-live-123"* && $l != *"ssm-secret-value"* ]] || { echo "leaked: $l"; return 1; }
  done
  [[ "$output" == *"::add-mask::sk-live-123"* ]]
  [[ "$output" == *"::add-mask::ssm-secret-value"* ]]
  # the contract variables are inherited by the command
  grep -qx 'PROJECT=shop' "$OUT.deploy"
  grep -qx 'APP_STAGE=Dev' "$OUT.deploy"
}

@test "deploy-lambda: reserved or invalid variable names are refused (PATH, DATABASE_URL, lower case)" {
  lambda_env
  local bad
  for bad in PATH DATABASE_URL AWS_REGION lower NODE_OPTIONS; do
    export DEPLOY_ENV_SSM="{\"$bad\":\"/{project}/ssm-values/x\"}"
    run "$SCRIPTS/deploy-lambda.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"deploy env: '$bad'"* ]]
  done
}

@test "deploy-lambda: a failing deploy command fails the job" {
  lambda_env
  export DEPLOY_COMMAND='exit 5'
  run "$SCRIPTS/deploy-lambda.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'deploy' failed (exit 5)"* ]]
}

@test "deploy-lambda: a secret key that does not exist fails naming the variable" {
  lambda_env
  export FAKE_SECRET_JSON='{"other":"x"}' DEPLOY_ENV_SECRETS='{"API_KEY":"{project}/{env}/keys#apiKey"}'
  run "$SCRIPTS/deploy-lambda.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"key 'apiKey' not found"* ]]
}

# ---- ECS ---------------------------------------------------------------------------------------------------------------

@test "ecs-deploy: reads cluster and service from SSM and forces a new deployment (nothing else)" {
  export ECS_CLUSTER_PARAM=/shop/api/Dev/ecs-cluster-name ECS_SERVICE_PARAM=/shop/api/Dev/ecs-service-name
  run "$SCRIPTS/ecs-deploy.sh"
  [ "$status" -eq 0 ]
  grep -q 'ecs update-service --region us-east-2 --cluster shop-cluster --service shop-service --force-new-deployment' "$FAKE_LOG"
  ! grep -q 'register-task-definition' "$FAKE_LOG"
}

@test "G22: ecs-verify-image fails when the tag does not exist and passes when it does" {
  export ECR_REPOSITORY=shop-api-dev IMAGE_TAG=abc123
  export FAKE_ECR_MISSING=1
  run "$SCRIPTS/ecs-verify-image.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist in ECR"* ]]
  unset FAKE_ECR_MISSING
  run "$SCRIPTS/ecs-verify-image.sh"
  [ "$status" -eq 0 ]
}

@test "build-push-image: plain docker build with the target and an immutable tag; latest only in dev" {
  export REGISTRY=reg.example.com ECR_REPOSITORY=shop-api-dev IMAGE_TAG=0123abc ENVIRONMENT=dev DOCKERFILE=apps/api/Dockerfile DOCKER_CONTEXT=. DOCKER_TARGET=runner
  run "$SCRIPTS/build-push-image.sh"
  [ "$status" -eq 0 ]
  grep -q 'docker build --file apps/api/Dockerfile --tag reg.example.com/shop-api-dev:0123abc --target runner --tag reg.example.com/shop-api-dev:latest .' "$FAKE_LOG"
  grep -q 'docker push reg.example.com/shop-api-dev:latest' "$FAKE_LOG"
  : >"$FAKE_LOG"
  export ENVIRONMENT=prod ECR_REPOSITORY=shop-api-prod
  run "$SCRIPTS/build-push-image.sh"
  [ "$status" -eq 0 ]
  ! grep -q ':latest' "$FAKE_LOG"
  grep -q 'docker push reg.example.com/shop-api-prod:0123abc' "$FAKE_LOG"
}

@test "build-push-image: an invalid tag is refused" {
  export REGISTRY=r ECR_REPOSITORY=x IMAGE_TAG='bad tag' ENVIRONMENT=dev DOCKERFILE=Dockerfile DOCKER_CONTEXT=.
  run "$SCRIPTS/build-push-image.sh"
  [ "$status" -eq 1 ]
}
