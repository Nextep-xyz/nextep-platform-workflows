#!/usr/bin/env bats
# G17 — the DORA telemetry job is ACTIVE and wired the way SPEC telemetria-dora requires, in every reusable workflow and contract.
# T0 (no secret, no HMAC), T3 (no tracking of people), T8 (the job runs no caller code and touches no cloud),
# T9 (every job stamps its start and end), T13 (callers keep the permission the new job needs).
# Subjects are discovered on disk: a workflow, a job or a caller added tomorrow is subject to it the day it appears.

load 'lib/gates'

JOB=telemetry-phone-home

@test "G17: each reusable workflow has an active telemetry-phone-home job wired as the spec requires" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G17
  local wf json cond
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    if grep -qE 'DORA-PLACEHOLDER' "$GATES_ROOT/$wf"; then
      gate_violation "$wf" "a DORA-PLACEHOLDER marker is left: the block was activated, remove the markers"
    fi
    if ! jq -e --arg j "$JOB" '.jobs | has($j)' <<<"$json" >/dev/null; then
      gate_violation "$wf" "has no '$JOB' job"
      continue
    fi
    jq -e --arg j "$JOB" '.jobs[$j].name == $j' <<<"$json" >/dev/null || gate_violation "$wf" "the name of the job must be '$JOB' (it is part of the required-check name)"
    # needs = every other job (discovered from the workflow itself): a job added tomorrow must be observed by telemetry
    jq -e --arg j "$JOB" '(.jobs[$j].needs // []) as $n | ([.jobs | keys[] | select(. != $j)] | sort) == ($n | sort)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "'$JOB' must need EVERY other job: needs is $(jq -c --arg j "$JOB" '.jobs[$j].needs // []' <<<"$json"), jobs are $(jq -c --arg j "$JOB" '[.jobs | keys[] | select(. != $j)]' <<<"$json")"
    cond="$(jq -r --arg j "$JOB" '.jobs[$j].if // "" | tostring' <<<"$json")"
    [[ $cond == *"always()"* ]] || gate_violation "$wf" "the 'if' of '$JOB' must contain always() (it reports failures and cancellations too)"
    [[ $cond == *"inputs.telemetry-url != ''"* ]] || gate_violation "$wf" "the 'if' of '$JOB' must be off when telemetry-url is empty"
    [[ $cond == *"inputs.telemetry-audience != ''"* ]] || gate_violation "$wf" "the 'if' of '$JOB' must be off when telemetry-audience is empty"
    if jq -e '.on.workflow_call.inputs | has("run-deploy")' <<<"$json" >/dev/null; then
      [[ $cond == *"inputs.run-deploy"* ]] || gate_violation "$wf" "the 'if' of '$JOB' must require inputs.run-deploy (a gate-only run is not a deployment)"
      [[ $cond == *"github.event_name != 'pull_request'"* ]] || gate_violation "$wf" "the 'if' of '$JOB' must exclude pull requests (a PR is not a deployment)"
    fi
    jq -e --arg j "$JOB" '.jobs[$j]["continue-on-error"] == true' <<<"$json" >/dev/null || gate_violation "$wf" "'$JOB' must set continue-on-error: true at job level (telemetry never turns a run red)"
    jq -e --arg j "$JOB" '(.jobs[$j]["timeout-minutes"] // 999) <= 5' <<<"$json" >/dev/null || gate_violation "$wf" "'$JOB' must set timeout-minutes <= 5"
    jq -e --arg j "$JOB" '.jobs[$j].permissions == {"contents": "read", "id-token": "write"}' <<<"$json" >/dev/null ||
      gate_violation "$wf" "'$JOB' permissions must be exactly {contents: read, id-token: write} (got $(jq -c --arg j "$JOB" '.jobs[$j].permissions' <<<"$json"))"
    jq -e '(.on.workflow_call.inputs["telemetry-url"] // {}) | .type == "string" and .default == ""' <<<"$json" >/dev/null || gate_violation "$wf" "input telemetry-url must exist (string, default \"\")"
    jq -e '(.on.workflow_call.inputs["telemetry-audience"] // {}) | .type == "string" and .default == ""' <<<"$json" >/dev/null || gate_violation "$wf" "input telemetry-audience must exist (string, default \"\")"
    jq -e '(.on.workflow_call.secrets // {}) | keys | map(select(test("TELEMETRY"))) | length == 0' <<<"$json" >/dev/null || gate_violation "$wf" "a TELEMETRY secret is declared: authentication is OIDC, there is no shared secret"
  done
  gate_finish G17
}

@test "G17: each contract matches the activation (inputs, no secret, the job listed, no marker)" {
  gate_require_tools yq jq
  gate_discover G17 contracts -maxdepth 1 -type f -name '*.contract.yml'
  local c json
  for c in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$c")"
    if grep -qE 'DORA-PLACEHOLDER' "$GATES_ROOT/$c"; then
      gate_violation "$c" "a DORA-PLACEHOLDER marker is left in the contract"
    fi
    jq -e '.inputs | has("telemetry-url") and has("telemetry-audience")' <<<"$json" >/dev/null || gate_violation "$c" "telemetry-url and telemetry-audience must be listed as inputs"
    jq -e --arg j "$JOB" '.jobs | index($j) != null' <<<"$json" >/dev/null || gate_violation "$c" "the job '$JOB' is not listed"
    jq -e '(.secrets // {}) | length == 0' <<<"$json" >/dev/null || gate_violation "$c" "declares secrets: the telemetry has none (OIDC)"
  done
  gate_finish G17
}

@test "G17: the telemetry composite exists" {
  gate_discover G17 .github/actions/telemetry -type f -name action.yml
  gate_finish G17
}

@test "T0: no shared secret and no HMAC anywhere in the workflows, composites, scripts and contracts" {
  gate_discover T0 .github scripts contracts -type f '(' -name '*.yml' -o -name '*.yaml' -o -name '*.sh' ')'
  local f n
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS=: read -r n _; do
      gate_violation "$f" "line $n: a shared secret or an HMAC signature (telemetry authenticates with OIDC only)"
    done < <(grep -nEi 'TELEMETRY_TOKEN|X-Signature|openssl +dgst|hmac' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done
  gate_finish T0
}

@test "T3: nothing that carries telemetry refers to the actor (no tracking of people)" {
  gate_discover T3 .github/actions/telemetry scripts -type f '(' -name 'action.yml' -o -name 'telemetry-*.sh' -o -name 'telemetry.sh' ')'
  local f n
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS=: read -r n _; do
      gate_violation "$f" "line $n: refers to the actor (github.actor / triggering_actor / GITHUB_ACTOR): telemetry never identifies people"
    done < <(grep -nEi '(^|[^a-z_])(github\.)?(triggering_)?actor([^a-z_]|$)|GITHUB_(TRIGGERING_)?ACTOR' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done
  gate_finish T3
}

@test "T8: the telemetry job runs no caller code and touches no cloud: one step, the internal composite, no checkout, no run" {
  gate_require_tools yq jq
  gate_discover_lego_workflows T8
  local wf json
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e --arg j "$JOB" '.jobs | has($j)' <<<"$json" >/dev/null || continue # G17 reports the missing job
    jq -e --arg j "$JOB" '(.jobs[$j].steps | length) == 1' <<<"$json" >/dev/null || gate_violation "$wf" "'$JOB' must have exactly one step (the telemetry composite)"
    jq -e --arg j "$JOB" '(.jobs[$j].steps // []) | map(has("run")) | any | not' <<<"$json" >/dev/null || gate_violation "$wf" "'$JOB' has a 'run:' step: all the logic lives in the composite"
    jq -e --arg j "$JOB" '(.jobs[$j].steps // []) | map(.uses // "") | all(test("/\\.github/actions/telemetry@(main|[0-9a-f]{40})$"))' <<<"$json" >/dev/null ||
      gate_violation "$wf" "'$JOB' may only use the internal telemetry composite (found: $(jq -c --arg j "$JOB" '[.jobs[$j].steps[].uses]' <<<"$json"))"
    jq -e --arg j "$JOB" '(.jobs[$j].steps // []) | map(.uses // "") | map(test("checkout|aws-oidc|configure-aws-credentials|azure/login|google-github-actions/auth")) | any | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "'$JOB' checks out code or assumes a cloud role"
    jq -e --arg j "$JOB" '(.jobs[$j].steps // []) | map(.["continue-on-error"] == true and (.["timeout-minutes"] // 999) <= 5) | all' <<<"$json" >/dev/null ||
      gate_violation "$wf" "the step of '$JOB' must set continue-on-error: true and timeout-minutes <= 5"
    jq -e --arg j "$JOB" '.jobs[$j] | has("environment") | not' <<<"$json" >/dev/null || gate_violation "$wf" "'$JOB' declares an environment (it would change the token's claims and gate it behind approvals)"
  done
  gate_finish T8
}

@test "T13: every sandbox caller grants id-token: write, and one reports telemetry from variables on a tag (@v1)" {
  gate_require_tools yq jq
  gate_discover T13 test/sandbox/callers -type f -name '*.yml'
  local f json reporting=0
  for f in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$f")"
    jq -e '.permissions["id-token"] == "write"' <<<"$json" >/dev/null || gate_violation "$f" "the caller does not grant id-token: write (the deploy job already needs it; the telemetry job must not be what breaks a caller)"
    if jq -e '[.jobs[] | .with // {} | has("telemetry-url")] | any' <<<"$json" >/dev/null; then
      reporting=1
      jq -e '[.jobs[] | select((.with // {}) | has("telemetry-url")) | .with["telemetry-url"] | test("^\\$\\{\\{ *vars\\.")] | all' <<<"$json" >/dev/null || gate_violation "$f" "telemetry-url must come from a repository variable, never a literal"
      jq -e '[.jobs[] | select((.with // {}) | has("telemetry-url")) | (.with["telemetry-audience"] // "") | test("^\\$\\{\\{ *vars\\.")] | all' <<<"$json" >/dev/null || gate_violation "$f" "telemetry-audience must come from a repository variable, never a literal"
      jq -e '[.jobs[] | select((.with // {}) | has("telemetry-url")) | .uses | test("@v[0-9]+(\\.[0-9]+\\.[0-9]+)?$")] | all' <<<"$json" >/dev/null ||
        gate_violation "$f" "a caller that reports telemetry must pin the workflow by tag (@v1 or @vX.Y.Z): the collector checks job_workflow_ref"
    fi
  done
  if ((reporting == 0)); then
    gate_violation "test/sandbox/callers" "no sandbox caller reports telemetry (expected one with telemetry-url/telemetry-audience from vars and @v1)"
  fi
  gate_finish T13
}

# T9 — every job of every reusable workflow (but the telemetry job itself) stamps its start and its end (SPEC telemetria-dora 3.1): the telemetry job
# cannot read durations from the API without asking callers for `actions: read`, so the jobs record them themselves.
# Discovery is on disk: a job added tomorrow is subject to it the day it appears.
@test "T9: every job stamps its start (first step) and its end (last step, always) and exposes started-at/finished-at" {
  gate_require_tools yq jq
  gate_discover_lego_workflows T9
  local wf json job
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    while IFS= read -r job; do
      [[ $job == "$JOB" ]] && continue # the observer stamps nothing: it has exactly one step (T8) and reads the stamps of the others
      jq -e --arg j "$job" '.jobs[$j].outputs["started-at"] == "${{ steps.stamp-start.outputs.epoch }}"' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job' does not expose started-at from the step 'stamp-start'"
      jq -e --arg j "$job" '.jobs[$j].outputs["finished-at"] == "${{ steps.stamp-end.outputs.epoch }}"' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job' does not expose finished-at from the step 'stamp-end'"
      jq -e --arg j "$job" '.jobs[$j].steps[0].id == "stamp-start"' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job': the first step is not the start stamp (id: stamp-start)"
      jq -e --arg j "$job" '.jobs[$j].steps[-1].id == "stamp-end" and ((.jobs[$j].steps[-1].if // "") | tostring | contains("always()"))' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job': the last step is not the end stamp (id: stamp-end) with 'if: always()'"
    done < <(jq -r '.jobs | keys[]' <<<"$json")
  done
  gate_finish T9
}
