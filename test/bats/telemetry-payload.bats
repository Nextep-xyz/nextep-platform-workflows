#!/usr/bin/env bats
# T4 / T3 / T11 (builder half) — telemetry-build-payload.sh: every scenario produces a payload the closed schema accepts,
# the stage and result mapping of SPEC §3.4, the removed fields stay removed, and workflow.* come from the token's claims.

load 'telemetry-helpers'

setup() {
  require_tool jq
  require_tool ajv
  telemetry_env
  write_commits_file
  PAYLOAD="$TELEMETRY_DIR/telemetry-payload.json"
}

build() { run "$SCRIPTS/telemetry-build-payload.sh"; }

# ok_payload: the builder succeeded, wrote a payload and the schema accepts it
ok_payload() {
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$PAYLOAD" ]
  schema_valid "$PAYLOAD" || { ajv validate -s "$SCHEMA" -d "$PAYLOAD" --strict=false 2>&1 | head -20; return 1; }
}

jqp() { jq -r "$1" "$PAYLOAD"; }

@test "success on cicd: a closed-schema payload with the identity, source, target, stages and timing of SPEC 3.3" {
  build
  ok_payload
  [ "$(jqp .schema_version)" = "1.0" ]
  [ "$(jqp .event_type)" = "deployment" ]
  [ "$(jqp .idempotency_key)" = "example-org/example-service:9876543210:1" ]
  [ "$(jqp .emitted_at)" = "2026-10-29T15:04:10Z" ]
  [ "$(jqp .source.organization)" = "example-org" ]
  [ "$(jqp .source.repository)" = "example-org/example-service" ]
  [ "$(jqp .source.ref)" = "refs/heads/main" ]
  [ "$(jqp .source.sha)" = "$SHA_HEAD" ]
  [ "$(jqp .source.tree_sha)" = "$SHA_TREE" ]
  [ "$(jqp '.source.ancestry | length')" = "2" ]
  [ "$(jqp .source.event_name)" = "push" ]
  [ "$(jqp .source.run_id)" = "9876543210" ]
  [ "$(jqp .source.run_url)" = "https://github.com/example-org/example-service/actions/runs/9876543210" ]
  [ "$(jqp .target.project)" = "shop" ]
  [ "$(jqp .target.cloud)" = "aws" ]
  [ "$(jqp .target.environment)" = "prod" ]
  [ "$(jqp .target.region)" = "us-east-2" ]
  [ "$(jqp .target.service)" = "example-service" ]
  [ "$(jqp .target.kind)" = "aws-lambda" ]
  [ "$(jqp .result.status)" = "success" ]
  [ "$(jqp .result.failed_stage)" = "null" ]
  [ "$(jqp .result.rollback)" = "false" ]
  [ "$(jqp .result.circuit_breaker_triggered)" = "false" ]
  [ "$(jqp '.stages.gate | "\(.status) \(.duration_s)"')" = "success 192" ]
  [ "$(jqp '.stages.migration | "\(.status) \(.duration_s) \(.mode)"')" = "success 100 ssm-tunnel" ]
  [ "$(jqp '.stages.deploy | "\(.status) \(.duration_s)"')" = "success 243" ]
  [ "$(jqp '.artifact // "none"')" = "none" ]
  [ "$(jqp .timing.commit_at)" = "2026-10-29T13:31:07Z" ]
  [ "$(jqp .timing.started_at)" = "2026-10-29T14:55:10Z" ]
  [ "$(jqp .timing.finished_at)" = "2026-10-29T15:04:05Z" ]
  [ "$(jqp .timing.duration_s)" = "535" ]
}

@test "workflow.* come from the token's claims, never from the caller's GITHUB_WORKFLOW_REF (T11)" {
  build
  ok_payload
  [ "$(jqp .workflow.name)" = "lego-aws-cicd" ]
  [ "$(jqp .workflow.version_ref)" = "refs/tags/v1" ]
  [ "$(jqp .workflow.sha)" = "$SHA_WF" ]
  [ "$(jqp .workflow.run_attempt)" = "1" ]
  CLAIM_JOB_WORKFLOW_REF='example-org/nextep-platform-workflows/.github/workflows/lego-aws-environment-deploy.yml@refs/tags/v1.2.0' build
  ok_payload
  [ "$(jqp .workflow.name)" = "lego-aws-environment-deploy" ]
  [ "$(jqp .workflow.version_ref)" = "refs/tags/v1.2.0" ]
  CLAIM_JOB_WORKFLOW_REF='example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@refs/heads/main' build
  ok_payload
  [ "$(jqp .workflow.version_ref)" = "refs/heads/main" ]
}

@test "claims that are not a lego workflow ref or a 40-hex sha make the builder fail instead of inventing values" {
  local bad
  for bad in "" "garbage" "example-org/x/.github/workflows/deploy.yml@refs/heads/main" "example-org/x/.github/workflows/lego-aws-cicd.yml" "lego-aws-cicd.yml@refs/tags/v1"; do
    CLAIM_JOB_WORKFLOW_REF=$bad build
    [ "$status" -eq 1 ] || { echo "accepted '$bad'"; return 1; }
    [ ! -e "$PAYLOAD" ]
  done
  CLAIM_JOB_WORKFLOW_SHA=zzz build
  [ "$status" -eq 1 ]
}

@test "T3: no actor and no lead_time_s anywhere in the payload, whatever the environment carries" {
  export GITHUB_ACTOR=$SECRET_ACTOR GITHUB_TRIGGERING_ACTOR=$SECRET_ACTOR
  build
  ok_payload
  ! grep -q "$SECRET_ACTOR" "$PAYLOAD"
  [ "$(jq '[.. | objects | keys[]] | map(select(. == "actor" or . == "lead_time_s" or . == "triggering_actor")) | length' "$PAYLOAD")" = "0" ]
}

@test "target.environment is the input byte for byte: no lower-casing and no mapping (C6)" {
  INPUT_ENVIRONMENT=Prod build
  ok_payload
  [ "$(jqp .target.environment)" = "Prod" ]
  INPUT_ENVIRONMENT=stg build
  ok_payload
  [ "$(jqp .target.environment)" = "stg" ]
}

@test "gate failure: failure/gate, the later stages skipped with zero duration, migration mode none" {
  NEEDS_JSON="$(needs_cicd failure skipped skipped)" build
  ok_payload
  [ "$(jqp .result.status)" = "failure" ]
  [ "$(jqp .result.failed_stage)" = "gate" ]
  [ "$(jqp '.stages.migration | "\(.status) \(.duration_s) \(.mode)"')" = "skipped 0 none" ]
  [ "$(jqp '.stages.deploy | "\(.status) \(.duration_s)"')" = "skipped 0" ]
  [ "$(jqp .timing.duration_s)" = "192" ]
}

@test "migration failure: failure/migration, deploy skipped" {
  NEEDS_JSON="$(needs_cicd success failure skipped)" build
  ok_payload
  [ "$(jqp .result.failed_stage)" = "migration" ]
  [ "$(jqp .stages.deploy.status)" = "skipped" ]
}

@test "deploy failure: failure/deploy" {
  NEEDS_JSON="$(needs_cicd success success failure)" build
  ok_payload
  [ "$(jqp .result.status)" = "failure" ]
  [ "$(jqp .result.failed_stage)" = "deploy" ]
}

@test "cancelled wins over a failure and has no failed stage" {
  NEEDS_JSON="$(needs_cicd success success cancelled)" build
  ok_payload
  [ "$(jqp .result.status)" = "cancelled" ]
  [ "$(jqp .result.failed_stage)" = "null" ]
  [ "$(jqp .stages.deploy.status)" = "cancelled" ]
  NEEDS_JSON="$(needs_cicd failure skipped cancelled)" build
  [ "$(jqp .result.status)" = "cancelled" ]
}

@test "no migration job (skipped): stages.migration is skipped with mode none" {
  NEEDS_JSON="$(needs_cicd success skipped success)" build
  ok_payload
  [ "$(jqp '.stages.migration | "\(.status) \(.mode)"')" = "skipped none" ]
  [ "$(jqp .result.status)" = "success" ]
}

@test "iam-direct: the migration ran but the collector's enum has no such mode, so mode is omitted" {
  INPUT_DB_ACCESS=iam-direct build
  ok_payload
  [ "$(jqp '.stages.migration | has("mode")')" = "false" ]
  [ "$(jqp .stages.migration.status)" = "success" ]
}

@test "static and ecs compute: target.kind follows the compute" {
  INPUT_COMPUTE=static build
  ok_payload
  [ "$(jqp .target.kind)" = "aws-static" ]
  INPUT_COMPUTE=ecs build
  [ "$(jqp .target.kind)" = "aws-ecs" ]
}

@test "environment-deploy: stages.deploy folds infra-deploy and post-deploy (worst status, summed duration)" {
  FLOW=environment-deploy NEEDS_JSON="$(needs_envdeploy success success success success)" build
  ok_payload
  [ "$(jqp .workflow.name)" = "lego-aws-cicd" ] # the claim decides, not the flow
  [ "$(jqp '.stages.deploy | "\(.status) \(.duration_s)"')" = "success 150" ]
  [ "$(jqp '.stages.migration | "\(.status) \(.duration_s)"')" = "success 100" ]
  FLOW=environment-deploy NEEDS_JSON="$(needs_envdeploy success success success failure)" build
  ok_payload
  [ "$(jqp .result.failed_stage)" = "deploy" ]
  [ "$(jqp .stages.deploy.status)" = "failure" ]
  FLOW=environment-deploy NEEDS_JSON="$(needs_envdeploy success success skipped skipped)" build
  ok_payload
  [ "$(jqp .stages.deploy.status)" = "success" ]
  [ "$(jqp .stages.migration.status)" = "skipped" ]
}

@test "environment-deploy with image-tag is a rollback and carries artifact.image_tag; without it, no artifact" {
  FLOW=environment-deploy GITHUB_EVENT_NAME=workflow_dispatch INPUT_IMAGE_TAG=prod-9f8e7d6 NEEDS_JSON="$(needs_envdeploy success success skipped success)" build
  ok_payload
  [ "$(jqp .result.rollback)" = "true" ]
  [ "$(jqp .artifact.image_tag)" = "prod-9f8e7d6" ]
  [ "$(jqp .source.event_name)" = "workflow_dispatch" ]
  FLOW=environment-deploy GITHUB_EVENT_NAME=workflow_dispatch NEEDS_JSON="$(needs_envdeploy success success success success)" build
  ok_payload
  [ "$(jqp .result.rollback)" = "false" ]
  [ "$(jqp 'has("artifact")')" = "false" ]
}

@test "cicd never reports a rollback or an artifact, even if an image-tag is in the environment" {
  INPUT_IMAGE_TAG=prod-9f8e7d6 build
  ok_payload
  [ "$(jqp .result.rollback)" = "false" ]
  [ "$(jqp 'has("artifact")')" = "false" ]
}

@test "timing comes from the stamps (min start, max end); without stamps it falls back to now and stays schema-valid" {
  NEEDS_JSON='{"quality-and-security-gate":{"result":"success","outputs":{}},"database-migration":{"result":"skipped","outputs":{}},"deploy":{"result":"success","outputs":{}}}' build
  ok_payload
  [ "$(jqp .timing.started_at)" = "$(jqp .timing.finished_at)" ]
  [ "$(jqp .timing.finished_at)" = "2026-10-29T15:04:10Z" ]
  [ "$(jqp .timing.duration_s)" = "0" ]
  [ "$(jqp .stages.gate.duration_s)" = "0" ]
}

@test "a re-run of the job (new run_attempt) keeps finished_at and changes only the attempt and the key" {
  build
  ok_payload
  first_finish="$(jqp .timing.finished_at)"
  first_key="$(jqp .idempotency_key)"
  TELEMETRY_NOW_EPOCH=1793999999 GITHUB_RUN_ATTEMPT=2 build
  ok_payload
  [ "$(jqp .timing.finished_at)" = "$first_finish" ]
  [ "$(jqp .idempotency_key)" != "$first_key" ]
  [ "$(jqp .idempotency_key)" = "example-org/example-service:9876543210:2" ]
  [ "$(jqp .workflow.run_attempt)" = "2" ]
}

@test "ancestry is capped at 100 entries" {
  jq -c '.ancestry = [range(0;100) | {sha: "cccccccccccccccccccccccccccccccccccccccc", at: "2026-10-29T12:02:11Z"}]' "$TELEMETRY_DIR/telemetry-commits.json" >"$BATS_TEST_TMPDIR/c.json"
  mv "$BATS_TEST_TMPDIR/c.json" "$TELEMETRY_DIR/telemetry-commits.json"
  build
  ok_payload
  [ "$(jqp '.source.ancestry | length')" = "100" ]
}

@test "no event: a pull request, run-deploy false, no deploy outcome, no commit data, unknown flow" {
  GITHUB_EVENT_NAME=pull_request build
  [ "$status" -eq 10 ]
  [ ! -e "$PAYLOAD" ]
  INPUT_RUN_DEPLOY=false build
  [ "$status" -eq 10 ]
  NEEDS_JSON="$(needs_cicd success success skipped)" build
  [ "$status" -eq 10 ]
  [[ "$output" == *"no deploy outcome"* ]]
  rm -f "$TELEMETRY_DIR/telemetry-commits.json"
  build
  [ "$status" -eq 10 ]
  write_commits_file
  FLOW=nonsense build
  [ "$status" -eq 1 ]
}

@test "a stale payload from a previous run is removed when there is no event" {
  build
  [ -s "$PAYLOAD" ]
  GITHUB_EVENT_NAME=pull_request build
  [ "$status" -eq 10 ]
  [ ! -e "$PAYLOAD" ]
}

@test "malformed numeric inputs fail the builder instead of producing a bad payload" {
  GITHUB_RUN_ID=abc build
  [ "$status" -eq 1 ]
  GITHUB_RUN_ATTEMPT=0 build
  [ "$status" -eq 1 ]
  NEEDS_JSON='not json' build
  [ "$status" -eq 1 ]
}
