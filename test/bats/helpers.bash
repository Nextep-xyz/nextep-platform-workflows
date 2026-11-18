# shellcheck shell=bash
# Shared helpers for the bats tests of the scripts.

REPO_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
export REPO_ROOT
export SCRIPTS="$REPO_ROOT/scripts"

# Defaults equal to the contract defaults; tests override what they exercise.
common_env() {
  export INPUT_PROJECT=shop INPUT_ENVIRONMENT=dev INPUT_AWS_REGION=us-east-2
  export INPUT_PACKAGE_MANAGER=pnpm INPUT_NODE_VERSION=22 INPUT_NODE_VERSION_FILE="" INPUT_PNPM_VERSION=""
  export INPUT_PYTHON_VERSION="" INPUT_PYTHON_REQUIREMENTS=""
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

# A service on ECS without a database: environment-deploy with the database stage switched off (migrate=false).
ecs_nodb_env_deploy() {
  common_env
  export INPUT_COMPUTE=ecs INPUT_ENVIRONMENT=prod EVENT_NAME=workflow_dispatch REF_NAME=main INPUT_MIGRATE=false
  export INPUT_BRANCH_MAP='{"main":"prod"}' INPUT_INFRA_DEPLOY_COMMAND='pnpm --dir infra exec cdk deploy --all'
  export INPUT_ECR_REPOSITORY='shop-web-{env}'
}

static_cicd_env() {
  common_env
  export INPUT_COMPUTE=static INPUT_DEPLOY_COMMAND='pnpm --dir infra exec cdk deploy "ShopWebHosting-$APP_STAGE"'
}

# --- release repositories (next-version.bats) -----------------------------------------------------------------------------------
# A throwaway git repository shaped like this one (contracts, workflows, composites, scripts, docs, tests) with a tag of release
# in the canonical form that release.yml writes: the release commit is the CHILD of the source commit and is not in main.
# Every git call carries its identity and no signing, so the tests do not depend on the user's git config.

rr_git() { git -C "$RR" -c user.name=tester -c user.email=tester@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# rr_commit <subject> <file> [content]: writes <file> (default: appends a line) and commits it with the given subject.
# RR_BODY, if set, is the body of the commit message.
rr_commit() {
  local subject=$1 file=$2 content=${3:-}
  mkdir -p "$RR/$(dirname "$file")"
  if [[ -n $content ]]; then printf '%s\n' "$content" >"$RR/$file"; else printf 'change %s\n' "$RANDOM$RANDOM" >>"$RR/$file"; fi
  rr_git add -A
  if [[ -n ${RR_BODY:-} ]]; then rr_git commit -q -m "$subject" -m "$RR_BODY"; else rr_git commit -q -m "$subject"; fi
}

# rr_release <X.Y.Z>: cuts a release exactly the way release.yml does (detached child commit + annotated tag + moving alias).
rr_release() {
  local v=$1 src
  src=$(rr_git rev-parse HEAD)
  rr_git switch -q --detach "$src"
  rr_git commit -q --allow-empty -m "release: v${v} (internal references pinned to ${src})"
  rr_git tag -a "v${v}" -m "v${v}"
  rr_git tag -f "v${v%%.*}" "v${v}" >/dev/null
  rr_git switch -q main
}

# rr_edit_contract <yq expression> <subject>: edits the demo contract and commits it with the given subject.
rr_edit_contract() {
  yq -i "$1" "$RR/contracts/lego-aws-demo.contract.yml"
  rr_git add -A
  rr_git commit -q -m "$2"
}

# make_release_repo: creates $RR (under the test tmpdir) with a first commit and the release v1.0.0 already cut.
make_release_repo() {
  RR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$RR"
  git -C "$RR" init -q -b main
  mkdir -p "$RR/contracts" "$RR/.github/workflows" "$RR/.github/actions/demo" "$RR/scripts" "$RR/docs" "$RR/test"
  cat >"$RR/contracts/lego-aws-demo.contract.yml" <<'YAML'
workflow: lego-aws-demo
inputs:
  project:
    type: string
    required: true
  flavor:
    type: string
    default: "a"
  dry:
    type: boolean
    default: false
secrets: {}
outputs:
  result: {}
jobs:
  - build
  - ship
YAML
  printf 'name: demo\n' >"$RR/.github/workflows/lego-aws-demo.yml"
  printf 'name: self-ci\n' >"$RR/.github/workflows/self-ci.yml"
  printf 'name: release\n' >"$RR/.github/workflows/release.yml"
  printf 'name: demo\n' >"$RR/.github/actions/demo/action.yml"
  printf '#!/usr/bin/env bash\n' >"$RR/scripts/run.sh"
  printf 'notes\n' >"$RR/docs/notes.md"
  printf 'readme\n' >"$RR/README.md"
  printf '@test "x" { true; }\n' >"$RR/test/t.bats"
  rr_git add -A
  rr_git commit -q -m "feat: Add the demo workflow"
  rr_release 1.0.0
  export NEXT_VERSION_REPORT="$BATS_TEST_TMPDIR/report.md"
}
