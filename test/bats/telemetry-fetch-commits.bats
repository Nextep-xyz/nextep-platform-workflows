#!/usr/bin/env bats
# T5 — telemetry-fetch-commits.sh: ONE call to the commits endpoint (per_page=100, the job's token, no checkout);
# anything unexpected leaves no file and the script still exits 0 (telemetry never breaks the pipeline).

load 'telemetry-helpers'

setup() {
  require_tool jq
  telemetry_env
  rm -f "$TELEMETRY_DIR/telemetry-commits.json"
  OUT="$TELEMETRY_DIR/telemetry-commits.json"
}

run_fetch() { run "$SCRIPTS/telemetry-fetch-commits.sh"; }

@test "one call, per_page=100, sha of the run; the file has tree_sha, commit_at and the ancestry newest first" {
  route '/repos/example-org/example-service/commits' 0 200 "$(body_file "$(commits_json 3)")"
  run_fetch
  [ "$status" -eq 0 ]
  [ "$(calls 'repos/example-org/example-service/commits')" = "1" ]
  [ "$(calls 'curl')" = "1" ]
  grep -q "sha=$SHA_HEAD" "$FAKE_LOG"
  grep -q "per_page=100" "$FAKE_LOG"
  grep -q "https://api.github.com/repos/example-org/example-service/commits" "$FAKE_LOG"
  [ "$(jq -r .tree_sha "$OUT")" = "$SHA_TREE" ]
  [ "$(jq -r .commit_at "$OUT")" = "2026-10-29T13:31:07Z" ]
  [ "$(jq -r '.ancestry | length' "$OUT")" = "3" ]
  [ "$(jq -r '.ancestry[0].sha' "$OUT")" = "$SHA_HEAD" ]
  [ "$(jq -r '.ancestry[1].sha' "$OUT")" = "$SHA_PREV" ]
  [ "$(jq -r '.ancestry[0].at' "$OUT")" = "2026-10-29T13:31:07Z" ]
}

@test "the job's token goes in the request config, never in the arguments or the output" {
  route '/commits' 0 200 "$(body_file "$(commits_json)")"
  run_fetch
  [ "$status" -eq 0 ]
  grep -q "Authorization: Bearer $SECRET_GH_TOKEN" "$FAKE_CURL_STDIN_LOG"
  ! grep -q "$SECRET_GH_TOKEN" "$FAKE_LOG"
  [[ "$output" != *"$SECRET_GH_TOKEN"* ]]
}

@test "more than 100 commits in the answer: the ancestry keeps the first 100" {
  route '/commits' 0 200 "$(body_file "$(commits_json 120)")"
  run_fetch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ancestry | length' "$OUT")" = "100" ]
}

@test "the first commit is not the sha of the run: no file, a warning, exit 0" {
  route '/commits' 0 200 "$(body_file "$(commits_json | jq -c '.[0].sha = "dddddddddddddddddddddddddddddddddddddddd"')")"
  run_fetch
  [ "$status" -eq 0 ]
  [ ! -e "$OUT" ]
  [[ "$output" == *"::warning"* ]]
}

@test "404, 500, a curl failure and garbage leave no file and exit 0" {
  local case_
  for case_ in "0|404|{}" "0|500|{}" "6|200|{}" "0|200|garbage" "0|200|[]" '0|200|{"message":"Not Found"}'; do
    IFS='|' read -r rc code body <<<"$case_"
    : >"$FAKE_CURL_ROUTES"
    rm -f "$FAKE_CURL_ROUTES.used" "$OUT"
    route '/commits' "$rc" "$code" "$(body_file "$body")"
    run_fetch
    [ "$status" -eq 0 ] || { echo "case $case_: status $status"; return 1; }
    [ ! -e "$OUT" ] || { echo "case $case_ left a file"; return 1; }
    [[ "$output" == *"::warning"* ]] || { echo "case $case_ gave no warning"; return 1; }
  done
}

@test "a stale file from an earlier run is removed when the call fails" {
  write_commits_file
  route '/commits' 0 500
  run_fetch
  [ "$status" -eq 0 ]
  [ ! -e "$OUT" ]
}

@test "missing token or a malformed sha or repository: no call at all" {
  GH_TOKEN="" run_fetch
  [ "$status" -eq 0 ]
  GITHUB_SHA=nothex run_fetch
  [ "$status" -eq 0 ]
  GITHUB_REPOSITORY='no-slash' run_fetch
  [ "$status" -eq 0 ]
  [ "$(calls curl)" = "0" ]
  [ ! -e "$OUT" ]
}

@test "the script never checks out the repository and never runs git" {
  [ -f "$SCRIPTS/telemetry-fetch-commits.sh" ]
  ! grep -nE '\bgit\b|checkout' "$SCRIPTS/telemetry-fetch-commits.sh" | grep -v '^[0-9]*:[[:space:]]*#'
}
