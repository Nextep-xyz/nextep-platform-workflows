#!/usr/bin/env bash
# Telemetry: mints the OIDC token, builds the payload from its claims and posts it to <url>/v1/deployments.
# Exit code is ALWAYS 0: the collector (or anything else here) failing must never turn a pipeline red.
#   1. url and audience empty  => telemetry is off (silent). Otherwise both are VALIDATED before any request (T2, T12):
#      the audience is a plain slug, so this job cannot mint a token for a cloud provider.
#   2. needs "$TELEMETRY_DIR/telemetry-commits.json" (telemetry-fetch-commits.sh) and the id-token permission.
#   3. the token is masked before its first use, travels in a request config on stdin (never in arguments) and is never printed:
#      only job_workflow_ref and job_workflow_sha are shown, because they are what the collector validates.
#   4. 202/200 = sent (a 202 with provisional=true is sent too, but warns: the repository is not registered at the collector).
#      401/403/413/422 = definitive (no retry). 429/5xx/network = up to 3 attempts.
#      Not sent => "$TELEMETRY_DIR/telemetry-unsent.json" + the payload in the step summary (re-run the job to resend).
# Env: TELEMETRY_URL, TELEMETRY_AUDIENCE, ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN, plus everything telemetry-build-payload.sh reads,
#   TELEMETRY_RETRY_DELAY (seconds, default 2), TELEMETRY_DIR, GITHUB_STEP_SUMMARY, GITHUB_OUTPUT.
#
# Deliberately NO `set -e`: every failure ends in a warning and `exit 0`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/telemetry.sh
source "$here/lib/telemetry.sh"

dir="${TELEMETRY_DIR:-${RUNNER_TEMP:-/tmp}/telemetry}"
payload="$dir/telemetry-payload.json"
unsent="$dir/telemetry-unsent.json"
response="$dir/telemetry-response.json"
wf_ref="" wf_sha="" key=""

skip() { # skip <reason>: nothing is sent, nobody is alarmed beyond a warning
  warn "Telemetry not sent: $1"
  telemetry_summary "### Telemetry" "" "Not sent: $1" ""
  telemetry_output sent false
}

claims_block() {
  [[ -n $wf_ref ]] || return 0
  telemetry_summary "| | |" "|---|---|" "| job_workflow_ref | \`$wf_ref\` |" "| job_workflow_sha | \`$wf_sha\` |"
}

payload_block() {
  [[ -s $payload ]] || return 0
  telemetry_summary "" "<details><summary>Payload</summary>" "" '```json'
  [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || jq . "$payload" >>"$GITHUB_STEP_SUMMARY" 2>/dev/null
  telemetry_summary '```' "</details>" ""
}

# not_sent <what happened>: the payload is kept for the record and the run goes on
not_sent() {
  [[ ! -s $payload ]] || cp "$payload" "$unsent"
  warn "Telemetry not sent: $1. The deployment is NOT affected; re-run the job telemetry-phone-home to resend (payload in the step summary)."
  telemetry_summary "### Telemetry" "" "**Not sent (unsent):** $1" ""
  claims_block
  payload_block
  telemetry_output sent false
}

mint_token() { # prints the JWT; returns 1 when there is none
  local resp="$dir/telemetry-token-response.json" jwt
  [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] || return 2
  printf 'header = "Authorization: Bearer %s"\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" |
    curl --silent --show-error --fail --connect-timeout 5 --max-time 10 --retry 2 --retry-delay 2 -K - \
      -H 'Accept: application/json' --output "$resp" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${TELEMETRY_AUDIENCE}" >/dev/null 2>&1 || { rm -f "$resp"; return 1; }
  jwt="$(jq -r '.value // empty' "$resp" 2>/dev/null)"
  rm -f "$resp"
  [[ -n $jwt ]] || return 1
  printf '%s' "$jwt"
}

post() { # post <jwt>: up to 3 attempts; sets $code and $rc of the last one
  local jwt=$1 attempt delay="${TELEMETRY_RETRY_DELAY:-2}"
  code=000 rc=0
  for attempt in 1 2 3; do
    rm -f "$response"
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" |
      curl --silent --show-error --connect-timeout 5 --max-time 10 -K - -X POST \
        -H 'Content-Type: application/json' -H "X-Idempotency-Key: ${key}" \
        --data-binary @"$payload" --output "$response" --write-out '%{http_code}' "${TELEMETRY_URL%/}/v1/deployments" 2>/dev/null)"
    rc=$?
    [[ $rc -eq 0 && $code =~ ^[0-9]{3}$ ]] || code=000
    case $code in
      200 | 202) return 0 ;;
      000 | 429 | 5??) ((attempt == 3)) || sleep "$delay" ;;
      *) return 0 ;; # definitive (401, 403, 413, 422, ...): retrying cannot help
    esac
  done
  return 0
}

main() {
  # (1) off, or invalid configuration
  if [[ -z ${TELEMETRY_URL:-} || -z ${TELEMETRY_AUDIENCE:-} ]]; then
    log "Telemetry is off (telemetry-url and telemetry-audience are both needed)."
    return 0
  fi
  telemetry_valid_audience "$TELEMETRY_AUDIENCE" || { skip "telemetry-audience must be a plain lower-case slug ([a-z0-9-], 3 to 63 characters, no dots)"; return 0; }
  telemetry_valid_url "$TELEMETRY_URL" || { skip "telemetry-url must be an https URL without credentials, query or spaces"; return 0; }
  [[ ${GITHUB_EVENT_NAME:-} != pull_request && ${INPUT_RUN_DEPLOY:-true} != false ]] || { log "Telemetry: not a deployment (pull request or run-deploy=false)."; return 0; }
  if ! mkdir -p "$dir"; then skip "cannot write to $dir"; return 0; fi
  rm -f "$payload" "$unsent" "$response"

  # (2) prerequisites
  [[ -s $dir/telemetry-commits.json ]] || { skip "no commit data (the commits endpoint did not answer)"; return 0; }

  # (3) the token
  local jwt claims rc=0
  jwt="$(mint_token)" || rc=$?
  case $rc in
    0) ;;
    2) skip "the job has no id-token permission (ACTIONS_ID_TOKEN_REQUEST_URL is not set)"; return 0 ;;
    *) skip "the OIDC token request failed"; return 0 ;;
  esac
  mask "$jwt"
  claims="$(telemetry_jwt_payload "$jwt")" || { skip "the OIDC token is not a readable JWT"; return 0; }
  wf_ref="$(jq -r '.job_workflow_ref // empty' <<<"$claims" 2>/dev/null)"
  wf_sha="$(jq -r '.job_workflow_sha // empty' <<<"$claims" 2>/dev/null)"
  claims=""
  if ! telemetry_workflow_ref_ok "$wf_ref" || [[ ! $wf_sha =~ ^[0-9a-f]{40}$ ]]; then
    wf_ref="" wf_sha=""
    skip "the token has no usable job_workflow_ref/job_workflow_sha claims"
    return 0
  fi

  # (4) the payload
  local brc=0 bout
  bout="$(CLAIM_JOB_WORKFLOW_REF="$wf_ref" CLAIM_JOB_WORKFLOW_SHA="$wf_sha" "$here/telemetry-build-payload.sh" 2>&1)" || brc=$?
  case $brc in
    0) ;;
    10)
      log "$bout"
      telemetry_summary "### Telemetry" "" "No event: ${bout#*no event: }" ""
      telemetry_output sent false
      return 0
      ;;
    *) skip "the payload could not be built (${bout//$'\n'/ })"; return 0 ;;
  esac
  key="$(jq -r '.idempotency_key' "$payload")"

  # (5) send
  local code ecode="" rid=""
  post "$jwt"
  if [[ $code == 202 || $code == 200 ]]; then
    log "Telemetry sent (HTTP $code, ${key})."
    telemetry_summary "### Telemetry" "" "**Sent** (HTTP $code) · \`$key\`" ""
    # A 202 with provisional=true is a green that hides a problem: the event was stored apart because the repository is not registered.
    # Only the boolean is read from the body, never any other field.
    if [[ -s $response ]] && [[ "$(jq -r '.provisional // false' "$response" 2>/dev/null)" == true ]]; then
      warn "Telemetry sent, but the collector does not recognise this repository: the event is stored apart and will not count in any project's metrics until the repository is registered with the collector's owner."
      telemetry_summary "> :warning: **Unregistered repository.** The collector accepted the event but stored it apart; it will not appear in any project's metrics until the repository is registered. The deployment is NOT affected." ""
      telemetry_output provisional true
    fi
    claims_block
    payload_block
    telemetry_output sent true
    telemetry_output http-code "$code"
    return 0
  fi
  if [[ -s $response ]]; then
    ecode="$(telemetry_sanitize "$(jq -r '.error.code // empty' "$response" 2>/dev/null)" 64)"
    rid="$(telemetry_sanitize "$(jq -r '.error.request_id // empty' "$response" 2>/dev/null)" 64)"
  fi
  telemetry_output http-code "$code"
  not_sent "the collector answered HTTP $code${ecode:+ ($ecode)}${rid:+, request $rid}"
}

main
exit 0
