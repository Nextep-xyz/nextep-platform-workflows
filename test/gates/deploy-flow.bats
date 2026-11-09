#!/usr/bin/env bats
# Job-flow invariants of the quick deploy: a failed migration or gate means no deploy; run-deploy=false means only the gate.
# Applies to every lego-aws workflow that defines a `deploy` job.

load 'lib/gates'

@test "deploy runs only when the gate succeeded, the migration succeeded or was skipped, and run-deploy is true" {
  gate_require_tools yq jq
  gate_discover_lego_workflows FLOW
  local wf json cond mig_cond
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.jobs | has("deploy")' <<<"$json" >/dev/null || continue
    cond="$(jq -r '.jobs.deploy.if // ""' <<<"$json")"
    jq -e '.jobs.deploy.needs | index("quality-and-security-gate") != null and index("database-migration") != null' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job deploy must need quality-and-security-gate and database-migration"
    [[ $cond == *"needs.quality-and-security-gate.result == 'success'"* ]] ||
      gate_violation "$wf" "job deploy does not require the gate to succeed"
    [[ $cond == *"needs.database-migration.result == 'success'"* && $cond == *"needs.database-migration.result == 'skipped'"* ]] ||
      gate_violation "$wf" "job deploy must run only when the migration succeeded or was skipped (a failed migration means no deploy)"
    [[ $cond == *"inputs.run-deploy"* ]] || gate_violation "$wf" "job deploy ignores run-deploy"
    mig_cond="$(jq -r '.jobs["database-migration"].if // ""' <<<"$json")"
    [[ $mig_cond == *"inputs.run-deploy"* ]] || gate_violation "$wf" "job database-migration ignores run-deploy"
  done
  gate_finish FLOW
}
