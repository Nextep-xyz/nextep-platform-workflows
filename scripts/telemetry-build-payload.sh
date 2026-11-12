#!/usr/bin/env bash
# Telemetry: builds the deployment event of SPEC telemetria-dora 3.3/3.4 into "$TELEMETRY_DIR/telemetry-payload.json".
# Everything is assembled with `jq -n --arg/--argjson`, never by string interpolation. Closed schema: no actor, no lead time.
#   exit 0  payload written          exit 10 no event (reason on stderr; any old payload is removed)
#   exit 1  bad input (a message names it)
# Env: FLOW (cicd|environment-deploy), INPUT_PROJECT, INPUT_ENVIRONMENT (raw, as received), INPUT_AWS_REGION, INPUT_COMPUTE,
#   INPUT_DB_ACCESS, INPUT_IMAGE_TAG, INPUT_RUN_DEPLOY (optional), NEEDS_JSON (toJSON(needs), with the stamp outputs),
#   CLAIM_JOB_WORKFLOW_REF / CLAIM_JOB_WORKFLOW_SHA (claims of the OIDC token: the ONLY source of workflow.*),
#   GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, GITHUB_REF, GITHUB_SHA, GITHUB_EVENT_NAME, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
#   GITHUB_SERVER_URL, TELEMETRY_DIR, TELEMETRY_NOW_EPOCH (tests).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/telemetry.sh
source "$here/lib/telemetry.sh"

dir="${TELEMETRY_DIR:-${RUNNER_TEMP:-/tmp}/telemetry}"
payload="$dir/telemetry-payload.json"
commits="$dir/telemetry-commits.json"
mkdir -p "$dir"
rm -f "$payload"

no_event() {
  printf 'telemetry: no event: %s\n' "$*" >&2
  exit 10
}

flow="${FLOW:-}"
[[ $flow == cicd || $flow == environment-deploy ]] || die "telemetry: FLOW must be cicd or environment-deploy (got '$flow')"

# A pull request is not a deployment, and run-deploy=false is the gate-only mode.
[[ ${GITHUB_EVENT_NAME:-} != pull_request ]] || no_event "a pull request is not a deployment"
[[ ${INPUT_RUN_DEPLOY:-true} != false ]] || no_event "run-deploy is false"
[[ -s $commits ]] || no_event "no commit data (telemetry-fetch-commits.sh left no file)"

require_env INPUT_PROJECT INPUT_ENVIRONMENT INPUT_AWS_REGION INPUT_COMPUTE NEEDS_JSON GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER \
  GITHUB_REF GITHUB_SHA GITHUB_EVENT_NAME GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SERVER_URL
[[ ${GITHUB_RUN_ID} =~ ^[1-9][0-9]*$ ]] || die "telemetry: GITHUB_RUN_ID is not a positive integer"
[[ ${GITHUB_RUN_ATTEMPT} =~ ^[1-9][0-9]*$ ]] || die "telemetry: GITHUB_RUN_ATTEMPT is not a positive integer"
jq -e 'type == "object"' <<<"$NEEDS_JSON" >/dev/null 2>&1 || die "telemetry: NEEDS_JSON is not a JSON object"

# workflow.* come from the token the collector validates, never from GITHUB_WORKFLOW_REF (that one is the CALLER's workflow).
ref="${CLAIM_JOB_WORKFLOW_REF:-}"
telemetry_workflow_ref_ok "$ref" || die "telemetry: the job_workflow_ref claim is not a lego-* reusable workflow ref"
[[ ${CLAIM_JOB_WORKFLOW_SHA:-} =~ ^[0-9a-f]{40}$ ]] || die "telemetry: the job_workflow_sha claim is not a 40-hex commit"
wf_path="${ref%%@*}"
wf_name="$(basename "$wf_path" .yml)"
wf_version_ref="${ref#*@}"

now="${TELEMETRY_NOW_EPOCH:-$(date -u +%s)}"
repo_name="${GITHUB_REPOSITORY#*/}"
image_tag=""
[[ $flow == environment-deploy ]] && image_tag="${INPUT_IMAGE_TAG:-}"

read -r -d '' program <<'JQ' || true
def num($s): if ($s | type) == "string" and ($s | test("^[0-9]+$")) then ($s | tonumber) else null end;
def res($j): ($needs[$j].result // "skipped");
def started($j): num($needs[$j].outputs["started-at"] // "");
def finished($j): num($needs[$j].outputs["finished-at"] // "");
def combine($rs):
  if ($rs | index("failure")) != null then "failure"
  elif ($rs | index("cancelled")) != null then "cancelled"
  elif ($rs | index("success")) != null then "success"
  else "skipped" end;
def stage($jobs):
  { status: combine([$jobs[] | res(.)]),
    start: ([$jobs[] | started(.)] | map(select(. != null)) | min),
    end:   ([$jobs[] | finished(.)] | map(select(. != null)) | max),
    duration: ([$jobs[] | (started(.) as $s | finished(.) as $f | if $s != null and $f != null and $f >= $s then $f - $s else 0 end)] | add // 0) };
def out: { status: .status, duration_s: .duration };
def iso: todate;

stage(["quality-and-security-gate"]) as $g
| stage(["database-migration"]) as $m
| stage(if $flow == "cicd" then ["deploy"] else ["infra-deploy", "post-deploy"] end) as $d
| [$g.status, $m.status, $d.status] as $all
| (if ($all | index("cancelled")) != null then {status: "cancelled", failed: null}
   elif ($all | index("failure")) != null then
     {status: "failure", failed: ([["gate", $g], ["migration", $m], ["deploy", $d]] | map(select(.[1].status == "failure")) | .[0][0])}
   elif $d.status == "success" then {status: "success", failed: null}
   else null end) as $r
| if $r == null then {no_event: "no deploy outcome (the deploy stage is " + $d.status + " and nothing failed)"} else
  ([$g.start, $m.start, $d.start] | map(select(. != null)) | min) as $t0
  | ([$g.end, $m.end, $d.end] | map(select(. != null)) | max) as $t1
  | ($t0 // $now) as $started
  | ([($t1 // $now), $started] | max) as $finished
  | {
      schema_version: "1.0",
      event_type: "deployment",
      idempotency_key: ($repo + ":" + $run_id + ":" + $attempt),
      emitted_at: ($now | iso),
      workflow: { name: $wf_name, version_ref: $wf_version_ref, sha: $wf_sha, run_attempt: ($attempt | tonumber) },
      source: {
        organization: $owner, repository: $repo, ref: $ref, sha: $sha,
        tree_sha: $commits.tree_sha, ancestry: $commits.ancestry[:100],
        event_name: $event, run_id: ($run_id | tonumber),
        run_url: ($server + "/" + $repo + "/actions/runs/" + $run_id)
      },
      target: { project: $project, cloud: "aws", environment: $environment, region: $region, service: $service, kind: ("aws-" + $compute) }
    }
    + (if $image_tag != "" then {artifact: {image_tag: $image_tag[:200]}} else {} end)
    + {
      result: { status: $r.status, failed_stage: $r.failed, rollback: ($image_tag != ""), circuit_breaker_triggered: false },
      stages: {
        gate: ($g | out),
        migration: (($m | out) + (if $m.status == "skipped" then {mode: "none"} elif $db_access == "ssm-tunnel" then {mode: "ssm-tunnel"} else {} end)),
        deploy: ($d | out)
      },
      timing: { commit_at: $commits.commit_at, started_at: ($started | iso), finished_at: ($finished | iso), duration_s: ($finished - $started) }
    }
  end
JQ

tmp="$(mktemp "$dir/payload.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq -n --argjson needs "$NEEDS_JSON" --slurpfile commits_file "$commits" \
  --arg flow "$flow" --arg wf_name "$wf_name" --arg wf_version_ref "$wf_version_ref" --arg wf_sha "$CLAIM_JOB_WORKFLOW_SHA" \
  --arg owner "$GITHUB_REPOSITORY_OWNER" --arg repo "$GITHUB_REPOSITORY" --arg ref "$GITHUB_REF" --arg sha "$GITHUB_SHA" \
  --arg event "$GITHUB_EVENT_NAME" --arg run_id "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" --arg server "${GITHUB_SERVER_URL%/}" \
  --arg project "$INPUT_PROJECT" --arg environment "$INPUT_ENVIRONMENT" --arg region "$INPUT_AWS_REGION" --arg compute "$INPUT_COMPUTE" \
  --arg service "$repo_name" --arg db_access "${INPUT_DB_ACCESS:-}" --arg image_tag "$image_tag" --argjson now "$now" \
  '$commits_file[0] as $commits | '"$program" >"$tmp" || die "telemetry: could not build the payload"

reason="$(jq -r '.no_event // empty' "$tmp")"
[[ -z $reason ]] || no_event "$reason"
mv "$tmp" "$payload"
trap - EXIT
log "telemetry: payload built ($(jq -r '.idempotency_key' "$payload"))"
