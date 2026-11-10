#!/usr/bin/env bats
# resolve-template.sh — G20: unknown placeholders fail naming the placeholder; {password} is URL-encoded.

load 'helpers'

setup() {
  export TPL_PROJECT=shop TPL_STAGE=Dev TPL_ENV=dev TPL_REGION=us-east-2
}

@test "resolves project, stage, env and region" {
  run "$SCRIPTS/resolve-template.sh" t '/{project}/core/{stage}/{env}/{region}'
  [ "$status" -eq 0 ]
  [ "$output" = "/shop/core/Dev/dev/us-east-2" ]
}

@test "a template without placeholders is returned as is" {
  run "$SCRIPTS/resolve-template.sh" t 'plain-value'
  [ "$status" -eq 0 ]
  [ "$output" = "plain-value" ]
}

@test "G20: an unknown placeholder fails naming the placeholder and the input" {
  run "$SCRIPTS/resolve-template.sh" my-input '/{project}/{foo}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'my-input': unknown placeholder '{foo}'"* ]]
}

@test "db placeholders are rejected without --db-url" {
  run "$SCRIPTS/resolve-template.sh" t 'x-{password}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown placeholder '{password}'"* ]]
}

@test "G20: --db-url URL-encodes the password (@ : / ? # all survive)" {
  export TPL_USER=admin TPL_PASSWORD='p@ss:w/rd?#' TPL_HOST=127.0.0.1 TPL_PORT=5432 TPL_DB=shop_db TPL_SCHEMA=shop_schema TPL_SSLMODE=verify-full
  run "$SCRIPTS/resolve-template.sh" --db-url db-url-template 'postgresql://{user}:{password}@{host}:{port}/{db}?schema={schema}&sslmode={sslmode}'
  [ "$status" -eq 0 ]
  [ "$output" = "postgresql://admin:p%40ss%3Aw%2Frd%3F%23@127.0.0.1:5432/shop_db?schema=shop_schema&sslmode=verify-full" ]
}

@test "values that contain braces are not re-expanded" {
  export TPL_USER=a TPL_PASSWORD='{host}' TPL_HOST=h TPL_PORT=1 TPL_DB=d TPL_SCHEMA=s TPL_SSLMODE=require
  run "$SCRIPTS/resolve-template.sh" --db-url t '{user}:{password}@{host}'
  [ "$status" -eq 0 ]
  [ "$output" = "a:%7Bhost%7D@h" ]
}

@test "a placeholder whose input is empty fails instead of producing a broken value" {
  export TPL_USER=a TPL_PASSWORD=b TPL_HOST=h TPL_PORT=1 TPL_DB="" TPL_SCHEMA=s TPL_SSLMODE=require
  run "$SCRIPTS/resolve-template.sh" --db-url db-url-template 'x/{db}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"placeholder '{db}' has no value"* ]]
}

@test "unbalanced braces fail" {
  run "$SCRIPTS/resolve-template.sh" t '/{project'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unbalanced braces"* ]]
}

@test "--check validates placeholders without needing values and prints nothing" {
  unset TPL_PROJECT TPL_STAGE TPL_ENV TPL_REGION
  run "$SCRIPTS/resolve-template.sh" --check t '/{project}/{stage}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$SCRIPTS/resolve-template.sh" --check t '/{bad}'
  [ "$status" -eq 1 ]
}
