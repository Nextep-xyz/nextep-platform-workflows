#!/usr/bin/env bats
# validate-inputs.sh — the optional database stage of environment-deploy (input `migrate`, G-DB1).

load 'helpers'

run_validate() { run "$SCRIPTS/validate-inputs.sh" "$1"; }

@test "G-DB1: an ECS service without a database passes with migrate=false and nothing else" {
  ecs_nodb_env_deploy
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "G-DB1: the same caller without migrate=false still has to configure the database (the opt-out is explicit)" {
  ecs_nodb_env_deploy
  unset INPUT_MIGRATE
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'bastion-id-ssm-param' is required to migrate"* ]]
  export INPUT_MIGRATE=true
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'db-name' is required to migrate"* ]]
}

@test "G-DB1: with migrate=false every database input that carries a value is rejected, naming it" {
  local pair n v shown
  for pair in \
    INPUT_BASTION_ID_SSM_PARAM:/shop/core/{stage}/bastion-id INPUT_DB_ENDPOINT_SSM_PARAM:/shop/core/{stage}/db-endpoint \
    INPUT_DB_SECRET_ID:shop/{env}/db INPUT_DB_NAME:shop_db INPUT_DB_SCHEMA:shop INPUT_MIGRATION_PRE_COMMAND:true \
    INPUT_POST_MIGRATE_COMMAND:true INPUT_DB_ACCESS:iam-direct INPUT_MIGRATE_BEFORE_DEPLOY:true \
    INPUT_MIGRATION_COMMAND:"pnpm run db:migrate" INPUT_MIGRATION_VERIFY_COMMAND:"pnpm run db:status"; do
    n="${pair%%:*}"
    v="${pair#*:}"
    ecs_nodb_env_deploy
    export "$n=$v"
    run_validate environment-deploy
    [ "$status" -eq 1 ] || { echo "$n=$v was accepted with migrate=false"; return 1; }
    [[ "$output" == *"with migrate=false"* ]] || { echo "$n: $output"; return 1; }
    shown="$(tr '[:upper:]_' '[:lower:]-' <<<"${n#INPUT_}")"
    [[ "$output" == *"input '$shown'"* ]] || { echo "$n: the message does not name '$shown': $output"; return 1; }
  done
}

@test "G-DB1: the contract defaults of the two migration commands are harmless with migrate=false" {
  ecs_nodb_env_deploy
  export INPUT_MIGRATION_COMMAND="make migrate" INPUT_MIGRATION_VERIFY_COMMAND="make migrate-status" INPUT_DB_ACCESS=ssm-tunnel INPUT_MIGRATE_BEFORE_DEPLOY=false
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "G-DB1: migrate=false also applies to lambda, and a rollback by image-tag stays valid" {
  ecs_nodb_env_deploy
  export INPUT_COMPUTE=lambda INPUT_ECR_REPOSITORY=""
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ecs_nodb_env_deploy
  export INPUT_IMAGE_TAG=v1.2.3
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "G-DB1: compute=static ignores migrate (the default true does not fail it, false changes nothing, and its own rules stay)" {
  static_env_deploy
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  export INPUT_MIGRATE=true
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  export INPUT_MIGRATE=false
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  export INPUT_DB_NAME=shop_db
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'db-name' is not allowed with compute=static"* ]]
}

@test "G-DB1: migrate must be true or false" {
  ecs_nodb_env_deploy
  export INPUT_MIGRATE=maybe
  run_validate environment-deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'migrate' must be true or false (got 'maybe')"* ]]
}

@test "G-DB1: a caller that migrates (the v1.2.0 shape) is not affected by the new input" {
  env_deploy_env
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  hub_like_env_deploy
  run_validate environment-deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
