# shellcheck shell=bash
# Helpers of the telemetry tests (fictional data only: example-org, example-service, shop).
# shellcheck source=helpers.bash
load 'helpers'

SHA_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_PREV=cccccccccccccccccccccccccccccccccccccccc
SHA_TREE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_WF=0123456789abcdef0123456789abcdef01234567
WF_REF_V1='example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@refs/tags/v1'
SCHEMA="$REPO_ROOT/contracts/telemetry.schema.json"
# Values that must never reach a log, a summary, an output or the unsent payload.
SECRET_ACTOR=octocat-secret-actor
SECRET_GH_TOKEN=ghs_faketokenvalue
SECRET_REQ_TOKEN=request-token-value

# The environment a telemetry step gets from the composite (all of it comes through env:, never interpolated).
telemetry_env() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log" FAKE_CURL_STDIN_LOG="$BATS_TEST_TMPDIR/stdin.log" FAKE_CURL_SENT="$BATS_TEST_TMPDIR/sent.json"
  : >"$FAKE_LOG"
  : >"$FAKE_CURL_STDIN_LOG"
  export FAKE_CURL_ROUTES="$BATS_TEST_TMPDIR/routes.txt"
  : >"$FAKE_CURL_ROUTES"
  rm -f "$FAKE_CURL_ROUTES.used"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR" TELEMETRY_DIR="$BATS_TEST_TMPDIR/telemetry"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output.txt"
  : >"$GITHUB_STEP_SUMMARY"
  : >"$GITHUB_OUTPUT"
  mkdir -p "$TELEMETRY_DIR"
  export GITHUB_REPOSITORY=example-org/example-service GITHUB_REPOSITORY_OWNER=example-org GITHUB_REF=refs/heads/main
  export GITHUB_SHA=$SHA_HEAD GITHUB_EVENT_NAME=push GITHUB_RUN_ID=9876543210 GITHUB_RUN_ATTEMPT=1
  export GITHUB_SERVER_URL=https://github.com GITHUB_API_URL=https://api.github.com GH_TOKEN=$SECRET_GH_TOKEN
  # a workflow-ref of the CALLER: the builder must never use it for workflow.*
  export GITHUB_WORKFLOW_REF='example-org/example-service/.github/workflows/cicd.yml@refs/heads/main'
  export FLOW=cicd INPUT_PROJECT=shop INPUT_ENVIRONMENT=prod INPUT_AWS_REGION=us-east-2 INPUT_COMPUTE=lambda
  export INPUT_DB_ACCESS=ssm-tunnel INPUT_IMAGE_TAG="" INPUT_RUN_DEPLOY=true
  export TELEMETRY_URL=https://collector.example.com TELEMETRY_AUDIENCE=example-audience
  export ACTIONS_ID_TOKEN_REQUEST_URL='https://token.example.com/idtoken?api-version=2' ACTIONS_ID_TOKEN_REQUEST_TOKEN=$SECRET_REQ_TOKEN
  export TELEMETRY_NOW_EPOCH=1793286250 TELEMETRY_RETRY_DELAY=0
  export CLAIM_JOB_WORKFLOW_REF=$WF_REF_V1 CLAIM_JOB_WORKFLOW_SHA=$SHA_WF
  export NEEDS_JSON
  NEEDS_JSON="$(needs_cicd success success success)"
}

# stamp <result> <start> <end> -> a needs entry
stamp() {
  if [[ $1 == skipped ]]; then printf '{"result":"skipped","outputs":{}}'; else printf '{"result":"%s","outputs":{"started-at":"%s","finished-at":"%s"}}' "$1" "$2" "$3"; fi
}

# needs_cicd <gate> <migration> <deploy>: gate 192 s, migration 100 s, deploy 243 s => 535 s end to end
needs_cicd() {
  printf '{"quality-and-security-gate":%s,"database-migration":%s,"deploy":%s}' \
    "$(stamp "$1" 1793285710 1793285902)" "$(stamp "$2" 1793285902 1793286002)" "$(stamp "$3" 1793286002 1793286245)"
}

# needs_envdeploy <gate> <infra-deploy> <migration> <post-deploy>
needs_envdeploy() {
  printf '{"quality-and-security-gate":%s,"infra-deploy":%s,"database-migration":%s,"post-deploy":%s}' \
    "$(stamp "$1" 1793285710 1793285902)" "$(stamp "$2" 1793285902 1793286002)" "$(stamp "$3" 1793286002 1793286102)" "$(stamp "$4" 1793286102 1793286152)"
}

# commits_json [<n>]: what the commits endpoint returns (newest first), n entries (default 2)
commits_json() {
  local n=${1:-2}
  jq -cn --argjson n "$n" --arg head "$SHA_HEAD" --arg prev "$SHA_PREV" --arg tree "$SHA_TREE" '
    [range(0; $n) | {
       sha: (if . == 0 then $head elif . == 1 then $prev else (((. | tostring) + ("e" * 40))[0:40]) end),
       commit: { tree: { sha: (if . == 0 then $tree else $prev end) }, committer: { date: "2026-10-29T13:31:07Z" } } }]'
}

# a commits file as telemetry-fetch-commits.sh leaves it
write_commits_file() {
  jq -cn --arg head "$SHA_HEAD" --arg prev "$SHA_PREV" --arg tree "$SHA_TREE" \
    '{tree_sha: $tree, commit_at: "2026-10-29T13:31:07Z", ancestry: [{sha: $head, at: "2026-10-29T13:31:07Z"}, {sha: $prev, at: "2026-10-29T12:02:11Z"}]}' \
    >"$TELEMETRY_DIR/telemetry-commits.json"
}

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# mkjwt <job_workflow_ref> <job_workflow_sha>: an unsigned token shaped like the runner's (with an actor claim that must never leak)
mkjwt() {
  local h p
  h="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
  p="$(jq -cn --arg r "$1" --arg s "$2" --arg a "$SECRET_ACTOR" \
    '{job_workflow_ref: $r, job_workflow_sha: $s, repository: "example-org/example-service", actor: $a, sub: "repo:example-org/example-service:ref:refs/heads/main"}' | b64url)"
  printf '%s.%s.fakesignature' "$h" "$p"
}

# route <substring> <curl-rc> <http-status> [<body-file>]
route() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >>"$FAKE_CURL_ROUTES"; }

# token_route [<jwt>]: the OIDC endpoint answers with a token
token_route() {
  local jwt=${1:-$(mkjwt "$WF_REF_V1" "$SHA_WF")}
  JWT=$jwt
  printf '{"value":"%s"}' "$jwt" >"$BATS_TEST_TMPDIR/token.json"
  route 'token.example.com/idtoken' 0 200 "$BATS_TEST_TMPDIR/token.json"
}

# body_file <json>: writes a response body and prints its path
body_file() {
  local f
  f="$(mktemp "$BATS_TEST_TMPDIR/body.XXXXXX")"
  printf '%s' "$1" >"$f"
  printf '%s' "$f"
}

# schema_valid <file>: 0 when the schema accepts it
schema_valid() { ajv validate -s "$SCHEMA" -d "$1" --strict=false >/dev/null 2>&1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [[ ${REQUIRE_TOOLS:-} == 1 ]]; then echo "required tool '$1' is not installed"; return 1; fi
  skip "$1 not installed"
}

calls() { grep -c "$1" "$FAKE_LOG" || true; }
