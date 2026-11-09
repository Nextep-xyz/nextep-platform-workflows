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
