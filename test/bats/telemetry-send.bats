#!/usr/bin/env bats
# T2, T6, T7, T11, T12 — telemetry-send.sh: validates audience and URL BEFORE asking for a token, mints the OIDC token,
# builds the payload from the token's claims, posts it, never prints the token, and ALWAYS exits 0.

load 'telemetry-helpers'

setup() {
  require_tool jq
  telemetry_env
  write_commits_file
  PAYLOAD="$TELEMETRY_DIR/telemetry-payload.json"
  UNSENT="$TELEMETRY_DIR/telemetry-unsent.json"
}

send() { run "$SCRIPTS/telemetry-send.sh"; }

# every log surface the token could leak to
no_leak() {
  local v f visible
  # the ::add-mask:: command is how the runner learns what to redact: it is consumed by the runner, not shown. Anything else is a leak.
  visible="$(grep -v '^::add-mask::' <<<"$output" || true)"
  for v in "$JWT" "$SECRET_REQ_TOKEN" "$SECRET_GH_TOKEN" "$SECRET_ACTOR"; do
    [[ -n $v ]] || continue
    [[ "$visible" != *"$v"* ]] || { echo "leaked '${v:0:12}…' in the output"; return 1; }
    for f in "$GITHUB_STEP_SUMMARY" "$GITHUB_OUTPUT" "$PAYLOAD" "$UNSENT" "$FAKE_LOG"; do
      [[ ! -e $f ]] || ! grep -qF -- "$v" "$f" || { echo "leaked '${v:0:12}…' in $f"; return 1; }
    done
  done
}

happy_routes() {
  token_route
  route '/v1/deployments' 0 202 "$(body_file '{"accepted":true,"duplicate":false}')"
}

@test "happy path: token, payload from the claims, POST to <url>/v1/deployments with the bearer token, exit 0, no unsent file" {
  happy_routes
  send
  [ "$status" -eq 0 ]
  [ "$(calls 'token.example.com/idtoken')" = "1" ]
  grep -q 'token.example.com/idtoken?api-version=2&audience=example-audience' "$FAKE_LOG"
  grep -q "Authorization: Bearer $SECRET_REQ_TOKEN" "$FAKE_CURL_STDIN_LOG"
  [ "$(calls '/v1/deployments')" = "1" ]
  grep -q 'https://collector.example.com/v1/deployments' "$FAKE_LOG"
  grep -q -- '-X POST' "$FAKE_LOG"
  grep -q 'X-Idempotency-Key: example-org/example-service:9876543210:1' "$FAKE_LOG"
  grep -q "Authorization: Bearer $JWT" "$FAKE_CURL_STDIN_LOG"
  [ ! -e "$UNSENT" ]
  cmp "$PAYLOAD" "$FAKE_CURL_SENT"
  [ "$(jq -r .workflow.name "$PAYLOAD")" = "lego-aws-cicd" ]
  [ "$(jq -r .workflow.version_ref "$PAYLOAD")" = "refs/tags/v1" ]
  grep -q '^sent=true' "$GITHUB_OUTPUT"
  grep -q '^http-code=202' "$GITHUB_OUTPUT"
  no_leak
}

@test "T6: the token is masked before anything else and printed nowhere; only the two workflow claims reach the summary" {
  happy_routes
  send
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::$JWT"* ]]
  # the mask line comes before the first request that carries the token (the POST)
  mask_at="$(grep -n "::add-mask::$JWT" <<<"$output" | head -1 | cut -d: -f1)"
  [ -n "$mask_at" ]
  no_leak
  grep -q "$WF_REF_V1" "$GITHUB_STEP_SUMMARY"
  grep -q "$SHA_WF" "$GITHUB_STEP_SUMMARY"
  grep -q '202' "$GITHUB_STEP_SUMMARY"
  ! grep -q "$SECRET_ACTOR" "$GITHUB_STEP_SUMMARY"
  ! grep -qi 'repo:example-org/example-service:ref' "$GITHUB_STEP_SUMMARY"
}

@test "T11: the claims decide the workflow identity; a branch ref is still sent (the collector rejects it and the summary says why)" {
  token_route "$(mkjwt 'example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@refs/heads/main' "$SHA_WF")"
  route '/v1/deployments' 0 403 "$(body_file '{"error":{"code":"workflow_not_allowed","message":"x","request_id":"req-1"}}')"
  send
  [ "$status" -eq 0 ]
  [ "$(jq -r .workflow.version_ref "$UNSENT")" = "refs/heads/main" ]
  grep -q 'lego-aws-cicd.yml@refs/heads/main' "$GITHUB_STEP_SUMMARY"
}

@test "T11: a token without the workflow claims, or that is not a JWT, sends nothing and exits 0" {
  local bad
  for bad in "garbage" "a.b.c" "$(mkjwt '' "$SHA_WF")" "$(mkjwt "$WF_REF_V1" 'nothex')" "$(mkjwt 'deploy.yml@refs/heads/main' "$SHA_WF")"; do
    : >"$FAKE_CURL_ROUTES"
    rm -f "$FAKE_CURL_ROUTES.used"
    : >"$FAKE_LOG"
    token_route "$bad"
    route '/v1/deployments' 0 202
    send
    [ "$status" -eq 0 ] || { echo "token '$bad': status $status"; return 1; }
    [ "$(calls '/v1/deployments')" = "0" ] || { echo "token '$bad' was used to post"; return 1; }
    [[ "$output" == *"::warning"* ]]
  done
}

@test "T2: an audience that is not a plain slug never reaches the token endpoint (no request at all)" {
  local aud
  for aud in "sts.amazonaws.com" "api://AzureADTokenExchange" "https://collector.example.com" "//iam.googleapis.com/projects/1" "Upper-Case" "has space" "a&audience=sts.amazonaws.com" "ab" "-leading-dash" "x;y" 'a$b' ""; do
    : >"$FAKE_LOG"
    TELEMETRY_AUDIENCE=$aud send
    [ "$status" -eq 0 ] || { echo "audience '$aud': status $status"; return 1; }
    [ ! -s "$FAKE_LOG" ] || { echo "audience '$aud' triggered a request"; cat "$FAKE_LOG"; return 1; }
  done
}

@test "T2: a valid slug audience is accepted" {
  happy_routes
  TELEMETRY_AUDIENCE=my-collector-prod send
  [ "$status" -eq 0 ]
  grep -q 'audience=my-collector-prod' "$FAKE_LOG"
}

@test "T12: the URL must be https, without credentials, spaces or a query; nothing is requested otherwise" {
  local url cred=user:pw@
  for url in "http://collector.example.com" "ftp://collector.example.com" "https://${cred}collector.example.com" "https://collector.example.com/a b" "https://collector.example.com?x=1" "collector.example.com" "https://" "https://collector.example.com/a;b" ""; do
    : >"$FAKE_LOG"
    TELEMETRY_URL=$url send
    [ "$status" -eq 0 ] || { echo "url '$url': status $status"; return 1; }
    [ ! -s "$FAKE_LOG" ] || { echo "url '$url' triggered a request"; return 1; }
  done
}

@test "T12: a trailing slash and a path prefix are kept sane: POST goes to <url>/v1/deployments" {
  happy_routes
  TELEMETRY_URL=https://collector.example.com/ send
  [ "$status" -eq 0 ]
  grep -q 'https://collector.example.com/v1/deployments' "$FAKE_LOG"
  ! grep -q 'collector.example.com//v1' "$FAKE_LOG"
}

@test "an empty url or audience means telemetry is off: silent, no request, exit 0" {
  TELEMETRY_URL="" send
  [ "$status" -eq 0 ]
  [[ "$output" != *"::warning"* ]]
  TELEMETRY_AUDIENCE="" send
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
}

@test "T7: 200 (duplicate) counts as sent" {
  token_route
  route '/v1/deployments' 0 200 "$(body_file '{"accepted":true,"duplicate":true}')"
  send
  [ "$status" -eq 0 ]
  [ ! -e "$UNSENT" ]
  grep -q '^sent=true' "$GITHUB_OUTPUT"
}

@test "T7: definitive 4xx answers are not retried, leave the unsent file and show the collector's code, never the body" {
  local case_ code
  for case_ in "401|invalid_token" "403|claim_mismatch" "413|payload_too_large" "422|schema_invalid"; do
    IFS='|' read -r status_code ecode <<<"$case_"
    : >"$FAKE_CURL_ROUTES"
    rm -f "$FAKE_CURL_ROUTES.used" "$UNSENT"
    : >"$FAKE_LOG"
    : >"$GITHUB_STEP_SUMMARY"
    token_route
    route '/v1/deployments' 0 "$status_code" "$(body_file "{\"error\":{\"code\":\"$ecode\",\"message\":\"the value xyz-internal was wrong\",\"request_id\":\"req-9\"}}")"
    send
    [ "$status" -eq 0 ] || { echo "$status_code: status $status"; return 1; }
    [ "$(calls '/v1/deployments')" = "1" ] || { echo "$status_code was retried"; return 1; }
    [ -s "$UNSENT" ]
    [[ "$output" == *"::warning"* ]]
    [[ "$output" == *"$ecode"* ]]
    [[ "$output" != *"xyz-internal"* ]]
    grep -q "$ecode" "$GITHUB_STEP_SUMMARY"
    grep -q "req-9" "$GITHUB_STEP_SUMMARY"
    grep -q '^sent=false' "$GITHUB_OUTPUT"
    no_leak
  done
}

@test "T7: 503 then 202: retried, sent" {
  token_route
  route '/v1/deployments' 0 503
  route '/v1/deployments' 0 202 "$(body_file '{"accepted":true}')"
  send
  [ "$status" -eq 0 ]
  [ "$(calls '/v1/deployments')" = "2" ]
  [ ! -e "$UNSENT" ]
}

@test "T7: a steady 500, 429 or timeout: three attempts, unsent file, a warning, exit 0" {
  local case_
  for case_ in "0|500" "0|429" "28|200" "6|200"; do
    IFS='|' read -r rc code <<<"$case_"
    : >"$FAKE_CURL_ROUTES"
    rm -f "$FAKE_CURL_ROUTES.used" "$UNSENT"
    : >"$FAKE_LOG"
    token_route
    route '/v1/deployments' "$rc" "$code"
    send
    [ "$status" -eq 0 ] || { echo "$case_: status $status"; return 1; }
    [ "$(calls '/v1/deployments')" = "3" ] || { echo "$case_: $(calls '/v1/deployments') attempts"; return 1; }
    [ -s "$UNSENT" ]
    [[ "$output" == *"::warning"* ]]
    grep -q "unsent\|not sent\|NOT sent" "$GITHUB_STEP_SUMMARY"
    jq -e . "$UNSENT" >/dev/null
    no_leak
  done
}

@test "T7: the unsent file is the exact payload and the summary prints it in a details block" {
  token_route
  route '/v1/deployments' 0 500
  send
  [ "$status" -eq 0 ]
  cmp "$PAYLOAD" "$UNSENT"
  grep -q '<details>' "$GITHUB_STEP_SUMMARY"
  grep -q '"idempotency_key"' "$GITHUB_STEP_SUMMARY"
}

@test "T7: the token endpoint failing (403, timeout, garbage, no value) means no POST and exit 0" {
  local case_
  for case_ in "0|403|{}" "28|200|{}" "6|200|{}" "0|200|garbage" '0|200|{"value":""}' '0|200|{"nothing":1}'; do
    IFS='|' read -r rc code body <<<"$case_"
    : >"$FAKE_CURL_ROUTES"
    rm -f "$FAKE_CURL_ROUTES.used"
    : >"$FAKE_LOG"
    route 'token.example.com/idtoken' "$rc" "$code" "$(body_file "$body")"
    route '/v1/deployments' 0 202
    send
    [ "$status" -eq 0 ] || { echo "$case_: status $status"; return 1; }
    [ "$(calls '/v1/deployments')" = "0" ] || { echo "$case_ posted"; return 1; }
    [[ "$output" == *"::warning"* ]]
  done
}

@test "T7: without id-token permission (no request URL/token) or without commit data: no request, exit 0, an explanation" {
  ACTIONS_ID_TOKEN_REQUEST_URL="" send
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
  [[ "$output" == *"id-token"* ]]
  rm -f "$TELEMETRY_DIR/telemetry-commits.json"
  send
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
}

@test "T7: a pull request or run-deploy false never asks for a token" {
  GITHUB_EVENT_NAME=pull_request send
  [ "$status" -eq 0 ]
  INPUT_RUN_DEPLOY=false send
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
}

@test "T7: a builder that cannot build (broken needs) is a warning, not a failure, and nothing is posted" {
  token_route
  route '/v1/deployments' 0 202
  NEEDS_JSON='not json' send
  [ "$status" -eq 0 ]
  [ "$(calls '/v1/deployments')" = "0" ]
  [[ "$output" == *"::warning"* ]]
}

@test "T7: no deploy outcome is a quiet skip: no POST and no scary warning" {
  token_route
  route '/v1/deployments' 0 202
  NEEDS_JSON="$(needs_cicd success success skipped)" send
  [ "$status" -eq 0 ]
  [ "$(calls '/v1/deployments')" = "0" ]
  grep -qi 'no deploy outcome' "$GITHUB_STEP_SUMMARY"
}

@test "the script is written to never fail: no 'set -e' and a final 'exit 0'" {
  ! grep -nE '^[[:space:]]*set -[a-z]*e' "$SCRIPTS/telemetry-send.sh" "$SCRIPTS/telemetry-fetch-commits.sh"
  tail -n 3 "$SCRIPTS/telemetry-send.sh" | grep -q '^exit 0$'
  tail -n 3 "$SCRIPTS/telemetry-fetch-commits.sh" | grep -q '^exit 0$'
}
