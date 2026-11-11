# shellcheck shell=bash
# Shared helpers for the bats tests of the scripts.

REPO_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
export REPO_ROOT
export SCRIPTS="$REPO_ROOT/scripts"

# Defaults equal to the contract defaults; tests override what they exercise.
common_env() {
  export INPUT_PROJECT=shop INPUT_ENVIRONMENT=dev INPUT_AWS_REGION=us-east-2
  export INPUT_PACKAGE_MANAGER=pnpm INPUT_NODE_VERSION=22 INPUT_NODE_VERSION_FILE="" INPUT_PNPM_VERSION=""
  export INPUT_BRANCH_MAP="" INPUT_DB_PORT=5432 INPUT_DB_SSL_MODE=verify-full INPUT_MIGRATION_TIMEOUT_MINUTES=20
  export INPUT_BASTION_ID_SSM_PARAM="" INPUT_DB_ENDPOINT_SSM_PARAM="" INPUT_DB_SECRET_ID="" INPUT_DB_NAME="" INPUT_DB_SCHEMA=""
  export INPUT_DB_URL_TEMPLATE='postgresql://{user}:{password}@{host}:{port}/{db}?schema={schema}&sslmode={sslmode}'
  export INPUT_ECR_REPOSITORY="" INPUT_ECS_CLUSTER_SSM_PARAM="" INPUT_ECS_SERVICE_SSM_PARAM=""
  export INPUT_ECS_DEPLOY_MODE=force-new-deployment INPUT_RUN_DEPLOY=true
  export INPUT_DEPLOY_COMMAND="" INPUT_REQUIRED_SSM_PARAMS="[]" INPUT_REQUIRED_SECRETS="[]"
  export INPUT_DEPLOY_ENV_SSM="{}" INPUT_DEPLOY_ENV_SECRETS="{}"
  export INPUT_IMAGE_TAG="" INPUT_INFRA_DEPLOY_COMMAND="" INPUT_INFRA_BOOTSTRAP_COMMAND=""
  export EVENT_NAME=push REF_NAME=develop
}

cicd_ecs_env() {
  common_env
  export INPUT_COMPUTE=ecs
  export INPUT_ECS_CLUSTER_SSM_PARAM='/{project}/api/{stage}/ecs-cluster-name'
  export INPUT_ECS_SERVICE_SSM_PARAM='/{project}/api/{stage}/ecs-service-name'
  export INPUT_ECR_REPOSITORY='shop-api-{env}'
}

cicd_lambda_env() {
  common_env
  export INPUT_COMPUTE=lambda INPUT_DEPLOY_COMMAND='pnpm run deploy'
}

env_deploy_env() {
  common_env
  export INPUT_COMPUTE=lambda EVENT_NAME=workflow_dispatch REF_NAME=infra-deploy
  export INPUT_BRANCH_MAP='{"main":"prod","staging":"stg","infra-deploy":"dev"}'
  export INPUT_INFRA_DEPLOY_COMMAND='pnpm --filter infra run deploy:ci'
  export INPUT_BASTION_ID_SSM_PARAM='/{project}/core/{stage}/bastion-id'
  export INPUT_DB_ENDPOINT_SSM_PARAM='/{project}/core/{stage}/db-endpoint'
  export INPUT_DB_SECRET_ID='{project}/{env}/core/database-credentials'
  export INPUT_DB_NAME=shop_db INPUT_DB_SCHEMA=shop_schema
}

# A caller shaped like the lambdalith + DSQL one (fictional: project shop). IAM-direct database, two package roots.
hub_like_env() {
  common_env
  export INPUT_COMPUTE=lambda INPUT_DB_ACCESS=iam-direct INPUT_INSTALL_DIRS=app,infra INPUT_TEST_DATABASE_IMAGE=postgres:17
  export INPUT_DB_ENDPOINT_SSM_PARAM='/shop/{stage}/database-endpoint-host'
  export INPUT_DEPLOY_COMMAND='pnpm --dir infra exec cdk deploy --exclusively ShopApi-$APP_STAGE'
  export INPUT_HOTSWAP_ENVIRONMENTS='dev,stg' INPUT_POST_DEPLOY_COMMAND='node scripts/verify.mjs'
}

hub_like_env_deploy() {
  hub_like_env
  export EVENT_NAME=workflow_dispatch REF_NAME=infra-deploy INPUT_INFRA_DEPLOY_COMMAND='pnpm --dir infra exec cdk deploy --all'
  export INPUT_BRANCH_MAP='{"main":"prod","staging":"stg","develop":"dev","infra-deploy":"dev"}'
  export INPUT_MIGRATE_BEFORE_DEPLOY=true
}

# A static site (single-page app on object storage + CDN): no image, no database stage.
static_env_deploy() {
  common_env
  export INPUT_COMPUTE=static INPUT_ENVIRONMENT=prod EVENT_NAME=workflow_dispatch REF_NAME=main
  export INPUT_BRANCH_MAP='{"main":"prod"}' INPUT_INFRA_DEPLOY_COMMAND='cd infra && pnpm exec cdk deploy "ShopWebHosting-$APP_STAGE"'
}

static_cicd_env() {
  common_env
  export INPUT_COMPUTE=static INPUT_DEPLOY_COMMAND='pnpm --dir infra exec cdk deploy "ShopWebHosting-$APP_STAGE"'
}
