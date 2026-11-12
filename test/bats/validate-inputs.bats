#!/usr/bin/env bats
# validate-inputs.sh — enums, combinations per compute, G19 (OIDC stack), G21 (branch-map), G26 (event).

load 'helpers'

run_validate() { run "$SCRIPTS/validate-inputs.sh" "$1"; }

@test "cicd ecs: a minimal valid caller passes" {
  cicd_ecs_env
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "cicd lambda: a minimal valid caller passes" {
  cicd_lambda_env
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "environment-deploy: a minimal valid caller passes" {
  env_deploy_env
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}

@test "enums: bad project, environment, compute and package-manager are all reported at once" {
  cicd_ecs_env
  export INPUT_PROJECT=Shop INPUT_ENVIRONMENT=qa INPUT_COMPUTE=vm INPUT_PACKAGE_MANAGER=yarn
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'project'"* ]]
  [[ "$output" == *"input 'environment'"* ]]
  [[ "$output" == *"input 'compute'"* ]]
  [[ "$output" == *"input 'package-manager'"* ]]
}

@test "G9: db-ssl-mode weaker than require is rejected, require and verify-full pass" {
  local mode
  for mode in disable no-verify allow prefer ""; do
    cicd_ecs_env
    export INPUT_DB_SSL_MODE="$mode"
    run_validate cicd
    [ "$status" -eq 1 ]
    [[ "$output" == *"input 'db-ssl-mode'"* ]]
  done
  for mode in verify-full require; do
    cicd_ecs_env
    export INPUT_DB_SSL_MODE="$mode"
    run_validate cicd
    [ "$status" -eq 0 ]
  done
}

@test "G26: environment-deploy only accepts workflow_dispatch and names the offending event" {
  local ev
  for ev in push pull_request schedule pull_request_target; do
    env_deploy_env
    export EVENT_NAME="$ev"
    run_validate environment-deploy
    [ "$status" -eq 1 ]
    [[ "$output" == *"got event '$ev'"* ]]
  done
}

@test "G26: cicd rejects pull_request_target and schedule, accepts push, pull_request and workflow_dispatch" {
  local ev
  for ev in pull_request_target schedule; do
    cicd_ecs_env
    export EVENT_NAME="$ev"
    run_validate cicd
    [ "$status" -eq 1 ]
    [[ "$output" == *"got event '$ev'"* ]]
  done
  for ev in push pull_request workflow_dispatch; do
    cicd_ecs_env
    export EVENT_NAME="$ev"
    run_validate cicd
    [ "$status" -eq 0 ]
  done
}

@test "G21: branch develop with environment=prod fails and names both" {
  cicd_ecs_env
  export INPUT_BRANCH_MAP='{"develop":"dev","main":"prod"}' INPUT_ENVIRONMENT=prod REF_NAME=develop
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch 'develop' maps to 'dev'"* ]]
  [[ "$output" == *"environment is 'prod'"* ]]
}

@test "G21: a branch missing from branch-map cannot deploy" {
  env_deploy_env
  export REF_NAME=feature-x
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch 'feature-x' is not in branch-map"* ]]
}

@test "G21: environment-deploy without branch-map fails (it is the main barrier without GitHub Environments)" {
  env_deploy_env
  export INPUT_BRANCH_MAP=""
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'branch-map' is required in environment-deploy"* ]]
}

@test "G21: branch-map is not enforced on pull_request in cicd (the ref is not a branch)" {
  cicd_ecs_env
  export INPUT_BRANCH_MAP='{"main":"prod"}' EVENT_NAME=pull_request REF_NAME=12/merge INPUT_RUN_DEPLOY=false
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "G21: branch-map must be a JSON object of dev|stg|prod" {
  cicd_ecs_env
  export INPUT_BRANCH_MAP='{"main":"production"}'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'branch-map' must be a JSON object"* ]]
}

@test "G19: infra-deploy-command targeting the OIDC role stack fails naming the stack" {
  env_deploy_env
  export INPUT_INFRA_DEPLOY_COMMAND='cdk deploy --all DeploymentStack'
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"OIDC role stack 'DeploymentStack'"* ]]
  export INPUT_INFRA_DEPLOY_COMMAND='cdk deploy GitHubOidcStack'
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"OIDC role stack 'GitHubOidcStack'"* ]]
}

@test "G19: infra-bootstrap-command is covered too, and a similar-looking name does not false-positive" {
  env_deploy_env
  export INPUT_INFRA_BOOTSTRAP_COMMAND='cdk deploy OidcStack'
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"infra-bootstrap-command"* ]]
  export INPUT_INFRA_BOOTSTRAP_COMMAND='cdk deploy RegistryStack'
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}

@test "compute requirements: ecs without cluster, service and repository lists all three" {
  cicd_ecs_env
  export INPUT_ECS_CLUSTER_SSM_PARAM="" INPUT_ECS_SERVICE_SSM_PARAM="" INPUT_ECR_REPOSITORY=""
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"'ecs-cluster-ssm-param'"* ]]
  [[ "$output" == *"'ecs-service-ssm-param'"* ]]
  [[ "$output" == *"'ecr-repository'"* ]]
}

@test "compute requirements: lambda without deploy-command fails unless run-deploy is false" {
  cicd_lambda_env
  export INPUT_DEPLOY_COMMAND=""
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"'deploy-command'"* ]]
  export INPUT_RUN_DEPLOY=false
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "migration: a bastion without endpoint, secret and db-name is reported" {
  cicd_lambda_env
  export INPUT_BASTION_ID_SSM_PARAM='/{project}/core/{stage}/bastion-id'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"'db-endpoint-ssm-param'"* ]]
  [[ "$output" == *"'db-secret-id'"* ]]
  [[ "$output" == *"'db-name'"* ]]
}

@test "image-tag: only valid for compute=ecs and must be a valid tag" {
  env_deploy_env
  export INPUT_IMAGE_TAG=abc123
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"only applies when compute=ecs"* ]]
  env_deploy_env
  export INPUT_COMPUTE=ecs INPUT_ECR_REPOSITORY='shop-api-{env}' INPUT_IMAGE_TAG='bad tag!'
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid image tag"* ]]
  export INPUT_IMAGE_TAG=0123456789abcdef
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}

@test "G20: an unknown placeholder in any template input fails naming the placeholder and the input" {
  cicd_ecs_env
  export INPUT_ECS_CLUSTER_SSM_PARAM='/{project}/{foo}/cluster'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'ecs-cluster-ssm-param': unknown placeholder '{foo}'"* ]]
  cicd_ecs_env
  export INPUT_DB_URL_TEMPLATE='postgresql://{user}:{secret}@{host}'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'db-url-template': unknown placeholder '{secret}'"* ]]
}

@test "G20: db placeholders are not allowed outside db-url-template" {
  cicd_ecs_env
  export INPUT_ECR_REPOSITORY='shop-{user}'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown placeholder '{user}'"* ]]
}

@test "JSON inputs: malformed lists and objects are rejected, template items are checked" {
  cicd_lambda_env
  export INPUT_REQUIRED_SSM_PARAMS='not json' INPUT_DEPLOY_ENV_SSM='["x"]'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'required-ssm-params' must be a JSON array of strings"* ]]
  [[ "$output" == *"input 'deploy-env-ssm' must be a JSON object of strings"* ]]
  cicd_lambda_env
  export INPUT_DEPLOY_ENV_SECRETS='{"DB":"{project}/{nope}#key"}'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown placeholder '{nope}'"* ]]
}

@test "ecs-deploy-mode: only force-new-deployment exists in P1" {
  cicd_ecs_env
  export INPUT_ECS_DEPLOY_MODE=register-task-definition
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'ecs-deploy-mode'"* ]]
}

# ---- P2: lambdalith + DSQL ----------------------------------------------------------------------------------------

@test "P2 hub-like callers pass in both flows (iam-direct needs only the endpoint, no bastion/secret/db-name)" {
  hub_like_env
  run_validate cicd
  [ "$status" -eq 0 ]
  hub_like_env_deploy
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}

@test "GH3: db-access=iam-direct without db-endpoint-ssm-param names the input; ssm-tunnel still needs the P1 inputs" {
  hub_like_env_deploy
  export INPUT_DB_ENDPOINT_SSM_PARAM=""
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'db-endpoint-ssm-param' is required when db-access=iam-direct"* ]]

  hub_like_env_deploy
  export INPUT_DB_ACCESS=ssm-tunnel
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'bastion-id-ssm-param' is required to migrate"* ]]
  [[ "$output" == *"input 'db-secret-id' is required to migrate"* ]]

  hub_like_env_deploy
  export INPUT_DB_ACCESS=vpn
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'db-access' must be ssm-tunnel or iam-direct (got 'vpn')"* ]]
}

@test "GH3: a cicd caller with iam-direct and no endpoint does not migrate (no endpoint, no database stage)" {
  hub_like_env
  export INPUT_DB_ENDPOINT_SSM_PARAM=""
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "GH4: test-database-image needs a fixed tag or a digest; latest and untagged are rejected naming the input" {
  local img
  for img in postgres:latest postgres "Postgres:17" "postgres:17 --privileged"; do
    hub_like_env
    export INPUT_TEST_DATABASE_IMAGE="$img"
    run_validate cicd
    [ "$status" -eq 1 ]
    [[ "$output" == *"input 'test-database-image'"* ]] || { echo "$img: $output"; return 1; }
  done
  for img in postgres:17 postgres:16-alpine registry.example.com/team/pg:17.2 "postgres@sha256:$(printf 'a%.0s' {1..64})"; do
    hub_like_env
    export INPUT_TEST_DATABASE_IMAGE="$img"
    run_validate cicd
    [ "$status" -eq 0 ] || { echo "$img: $output"; return 1; }
  done
}

@test "install-dirs: absolute paths, '..' and spaces are rejected; a list of roots passes" {
  local d
  for d in /etc ../x "app, infra" "app;rm -rf /" "app/" "a..b"; do
    hub_like_env
    export INPUT_INSTALL_DIRS="$d"
    run_validate cicd
    [ "$status" -eq 1 ]
    [[ "$output" == *"input 'install-dirs'"* ]] || { echo "$d: $output"; return 1; }
  done
  for d in . app app,infra services/api,infra; do
    hub_like_env
    export INPUT_INSTALL_DIRS="$d"
    run_validate cicd
    [ "$status" -eq 0 ] || { echo "$d: $output"; return 1; }
  done
}

@test "GH9: hotswap-environments never admits prod (dev,stg passes)" {
  hub_like_env
  export INPUT_HOTSWAP_ENVIRONMENTS='dev,stg,prod'
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'hotswap-environments' must not include prod"* ]]
  hub_like_env
  export INPUT_HOTSWAP_ENVIRONMENTS='dev,stg'
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "GH6: post-deploy-command cannot deploy the OIDC role stack, in either flow, even with a project prefix" {
  local flow
  for flow in cicd environment-deploy; do
    if [[ $flow == cicd ]]; then hub_like_env; else hub_like_env_deploy; fi
    export INPUT_POST_DEPLOY_COMMAND='pnpm exec cdk deploy ShopGithubOidc --exclusively'
    run_validate "$flow"
    [ "$status" -eq 1 ]
    [[ "$output" == *"input 'post-deploy-command' mentions 'GithubOidc'"* ]] || { echo "$flow: $output"; return 1; }
  done
  hub_like_env_deploy
  export INPUT_INFRA_DEPLOY_COMMAND='cdk ls | grep -v ShopGithubOidc | xargs cdk deploy'
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'infra-deploy-command' mentions 'GithubOidc'"* ]]
  hub_like_env_deploy
  export INPUT_INFRA_DEPLOY_COMMAND='cdk ls | grep -viE "oidc|envmanager" | xargs cdk deploy'
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}

@test "GH7: the hub-like branch-map maps several branches to one environment and names an unmapped branch" {
  hub_like_env_deploy
  export REF_NAME=infra-deploy INPUT_ENVIRONMENT=dev
  run_validate environment-deploy
  [ "$status" -eq 0 ]
  export REF_NAME=feature-x
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch 'feature-x' is not in branch-map"* ]]
  export REF_NAME=develop INPUT_ENVIRONMENT=prod
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch 'develop' maps to 'dev' in branch-map but environment is 'prod'"* ]]
}

@test "migrate-before-deploy must be a boolean" {
  hub_like_env_deploy
  export INPUT_MIGRATE_BEFORE_DEPLOY=maybe
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'migrate-before-deploy' must be true or false"* ]]
}

@test "commands: {stage}, {env}, {project} and {region} are rejected (not expanded there) and name the variable to use" {
  hub_like_env_deploy
  export INPUT_LINT_COMMAND='pnpm lint --project {project}'
  export INPUT_INFRA_DEPLOY_COMMAND='cdk deploy "ShopApi-{stage}" -c e={env} -c r={region}'
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'lint-command' uses '{project}'"*'use $PROJECT'* ]]
  [[ "$output" == *"input 'infra-deploy-command' uses '{stage}'"*'use $APP_STAGE'* ]]
  [[ "$output" == *"input 'infra-deploy-command' uses '{env}'"*'use $APP_ENV'* ]]
  [[ "$output" == *"input 'infra-deploy-command' uses '{region}'"*'use $AWS_REGION'* ]]
}

@test "commands: shell braces and \${VAR} expansions are not mistaken for placeholders" {
  hub_like_env_deploy
  export INPUT_INFRA_DEPLOY_COMMAND='{ [ -z "$X" ] && echo none || cdk deploy "ShopApi-${APP_STAGE}" "Shop*-$APP_STAGE"; }'
  export INPUT_TEST_COMMAND='node -e "console.log({stage: 1})"'
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; } # `{stage: 1}` is not the placeholder `{stage}`: only the exact token counts
}

# --- compute: static ---------------------------------------------------------------------------------------------------
# G8: the tests below run WITH $GITHUB_OUTPUT defined (Actions always defines it); a path that only works without it
# is a path that does not work.

@test "static: a minimal environment-deploy caller needs no image, no database and passes, with GITHUB_OUTPUT defined" {
  static_env_deploy
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh-output"
  : >"$GITHUB_OUTPUT"
  run_validate environment-deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"compute=static"* ]]
}

@test "static: a minimal cicd caller passes (build + deploy-command) and requires deploy-command" {
  static_cicd_env
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh-output"
  : >"$GITHUB_OUTPUT"
  run_validate cicd
  [ "$status" -eq 0 ]
  export INPUT_DEPLOY_COMMAND=""
  run_validate cicd
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'deploy-command' is required"* ]]
}

@test "G5: static rejects every database input and names it" {
  local pair name value
  for pair in \
    'INPUT_BASTION_ID_SSM_PARAM=/{project}/core/{stage}/bastion-id' \
    'INPUT_DB_ENDPOINT_SSM_PARAM=/{project}/core/{stage}/db-endpoint' \
    'INPUT_DB_SECRET_ID={project}/{env}/db' \
    'INPUT_DB_NAME=shop_db' \
    'INPUT_DB_SCHEMA=shop_schema' \
    'INPUT_MIGRATION_PRE_COMMAND=pnpm run db:prep' \
    'INPUT_POST_MIGRATE_COMMAND=pnpm run db:seed' \
    'INPUT_DB_ACCESS=iam-direct' \
    'INPUT_MIGRATE_BEFORE_DEPLOY=true' \
    'INPUT_MIGRATION_COMMAND=pnpm run db:deploy' \
    'INPUT_MIGRATION_VERIFY_COMMAND=pnpm run db:status'; do
    name="${pair%%=*}"
    value="${pair#*=}"
    static_env_deploy
    export "$name=$value"
    run_validate environment-deploy
    [ "$status" -eq 1 ] || { echo "$name was accepted with compute=static"; return 1; }
    local shown="${name#INPUT_}"
    shown="$(tr '[:upper:]_' '[:lower:]-' <<<"$shown")"
    [[ "$output" == *"input '$shown' is not allowed with compute=static"* ]] || { echo "message for $name: $output"; return 1; }
  done
}

@test "static: the contract defaults of the migration commands are harmless (they cannot be told apart from 'not set')" {
  static_env_deploy
  export INPUT_MIGRATION_COMMAND="make migrate" INPUT_MIGRATION_VERIFY_COMMAND="make migrate-status" INPUT_DB_ACCESS=ssm-tunnel INPUT_MIGRATE_BEFORE_DEPLOY=false
  run_validate environment-deploy
  [ "$status" -eq 0 ]
}

@test "static: image-tag (rollback) is rejected like for lambda" {
  static_env_deploy
  export INPUT_IMAGE_TAG=abc123
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'image-tag'"* ]]
}

@test "static: the compute enum message lists static" {
  static_env_deploy
  export INPUT_COMPUTE=vm
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"lambda, ecs or static"* ]]
}

# ---- telemetry inputs (SPEC telemetria-dora, T2 and T12) --------------------------------------------------------------

@test "telemetry: both inputs valid (or both empty) pass in both flows" {
  cicd_lambda_env
  export INPUT_TELEMETRY_URL=https://collector.example.com INPUT_TELEMETRY_AUDIENCE=example-audience
  run_validate cicd
  [ "$status" -eq 0 ]
  env_deploy_env
  export INPUT_TELEMETRY_URL=https://collector.example.com/base INPUT_TELEMETRY_AUDIENCE=example-audience-2
  run_validate environment-deploy
  [ "$status" -eq 0 ]
  cicd_lambda_env
  export INPUT_TELEMETRY_URL="" INPUT_TELEMETRY_AUDIENCE=""
  run_validate cicd
  [ "$status" -eq 0 ]
}

@test "T2: an audience that is not a plain slug is rejected, naming the input (no cloud default audience can get through)" {
  local aud
  for aud in "sts.amazonaws.com" "api://AzureADTokenExchange" "Upper" "a b" "ab" "x&y"; do
    cicd_lambda_env
    export INPUT_TELEMETRY_URL=https://collector.example.com INPUT_TELEMETRY_AUDIENCE="$aud"
    run_validate cicd
    [ "$status" -eq 1 ] || { echo "accepted audience '$aud'"; return 1; }
    [[ "$output" == *"input 'telemetry-audience'"* ]]
  done
}

@test "T12: a URL that is not https, or carries credentials, a query or spaces, is rejected, naming the input" {
  local url cred=user:pw@
  for url in "http://collector.example.com" "https://${cred}collector.example.com" "https://collector.example.com?x=1" "collector.example.com" "https://collector.example.com/a b"; do
    cicd_lambda_env
    export INPUT_TELEMETRY_URL="$url" INPUT_TELEMETRY_AUDIENCE=example-audience
    run_validate cicd
    [ "$status" -eq 1 ] || { echo "accepted url '$url'"; return 1; }
    [[ "$output" == *"input 'telemetry-url'"* ]]
  done
}

@test "telemetry: only one of the two inputs set passes with a warning (telemetry stays off, the pipeline is not stopped)" {
  cicd_lambda_env
  export INPUT_TELEMETRY_URL=https://collector.example.com INPUT_TELEMETRY_AUDIENCE=""
  run_validate cicd
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning"* ]]
  [[ "$output" == *"telemetry-audience"* ]]
}
