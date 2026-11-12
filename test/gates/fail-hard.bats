#!/usr/bin/env bats
# `continue-on-error: true` only in telemetry and reporting; the gate, the migration and the deploy fail for real.
# And in the infra-deploy composite the guard of the prepare step runs BEFORE the deploy and cannot be skipped.

load 'lib/gates'

@test "no continue-on-error outside telemetry/reporting" {
  gate_require_tools yq jq
  gate_discover G-COE .github -type f '(' -name '*.yml' -o -name '*.yaml' ')'
  local f n
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r n; do
      gate_violation "$f" "step '$n' sets continue-on-error: true (allowed only in telemetry and reporting)"
    done < <(gate_json "$f" | jq -r '[(.jobs // {} | to_entries[] | select(.key | test("telemetry|report") | not) | .value.steps // [] | .[]), ((.runs.steps // [])[])] | .[] | select(.["continue-on-error"] == true) | .name // "(unnamed)"')
    # the same rule at JOB level: a job-level continue-on-error would let a failed gate, migration or deploy leave the run green
    while IFS= read -r n; do
      gate_violation "$f" "job '$n' sets continue-on-error: true (allowed only in telemetry and reporting jobs)"
    done < <(gate_json "$f" | jq -r '(.jobs // {}) | to_entries[] | select(.key | test("telemetry|report") | not) | select(.value["continue-on-error"] == true) | .key')
  done
  gate_finish G-COE
}

@test "infra-deploy composite: prepare, its guard and clean run before the deploy, and none of them can be skipped" {
  gate_require_tools yq jq
  gate_discover G-ORDER .github/actions/infra-deploy -type f -name action.yml
  local f="${GATE_SUBJECTS[0]}" json order deploy_at guard_at
  json="$(gate_json "$f")"
  order="$(jq -r '[.runs.steps[].name] | @json' <<<"$json")"
  deploy_at="$(jq -r '[.runs.steps[].name] | index("Deploy the infrastructure")' <<<"$json")"
  guard_at="$(jq -r '[.runs.steps[].name] | index("Prepare guard (the generated artifact is not empty)")' <<<"$json")"
  [[ $deploy_at != null && $guard_at != null ]] || gate_violation "$f" "the deploy or the prepare guard step is missing (steps: $order)"
  if [[ $deploy_at != null && $guard_at != null ]]; then
    ((guard_at < deploy_at)) || gate_violation "$f" "the prepare guard must run before the infra deploy"
  fi
  jq -e '[.runs.steps[] | select(.name | test("Prepare|Clean|Deploy the infrastructure")) | .if // empty] | length == 0' <<<"$json" >/dev/null ||
    gate_violation "$f" "prepare, guard, clean and deploy steps must not carry an 'if:' (they cannot be skipped)"
  gate_finish G-ORDER
}
