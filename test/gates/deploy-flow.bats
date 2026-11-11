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

@test "P2 (lambdalith + DSQL): the migration job is enabled by iam-direct and the post-deploy step runs after the deploy, with the role's account" {
  gate_require_tools yq jq
  gate_discover_lego_workflows FLOW-P2
  local wf json
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.jobs | has("deploy")' <<<"$json" >/dev/null || continue
    jq -r '.jobs["database-migration"].if' <<<"$json" | grep -q "inputs.db-access == 'iam-direct'" ||
      gate_violation "$wf" "job database-migration is not enabled by db-access=iam-direct with an endpoint"
    jq -r '.jobs["database-migration"].steps[] | select(.id == "tunnel") | .if' <<<"$json" | grep -q "inputs.db-access == 'ssm-tunnel'" ||
      gate_violation "$wf" "the SSM tunnel step must run only when db-access=ssm-tunnel (iam-direct opens no tunnel)"
    jq -e '[.jobs.deploy.steps[] | .uses // ""] | (map(test("/actions/deploy-lambda@")) | index(true)) as $d | (map(test("/actions/post-deploy@")) | index(true)) as $p | $d != null and $p != null and $p > $d' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job deploy must run post-deploy after the deploy step"
    jq -e '.jobs.deploy.steps[] | select((.uses // "") | test("/actions/(deploy-lambda|post-deploy)@")) | .with["aws-account-id"] == "${{ steps.oidc.outputs.account-id }}"' <<<"$json" | grep -qv true &&
      gate_violation "$wf" "deploy-lambda and post-deploy must get aws-account-id from the aws-oidc output"
  done
  gate_finish FLOW-P2
}

@test "P2 D3: migrate-before-deploy orders migration -> infra (true) or infra -> migration (false); post-deploy waits for both" {
  gate_require_tools yq jq
  gate_discover_lego_workflows FLOW-D3
  local wf json
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '(.on.workflow_call.inputs // {}) | has("migrate-before-deploy")' <<<"$json" >/dev/null || continue
    jq -e '.jobs["infra-deploy"].needs | index("database-migration-before-deploy") != null' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job infra-deploy must need database-migration-before-deploy (true => migrate first)"
    jq -r '.jobs["infra-deploy"].if // ""' <<<"$json" | grep -q "needs.database-migration-before-deploy.result == 'skipped'" ||
      gate_violation "$wf" "job infra-deploy must also run when database-migration-before-deploy was skipped (false => P1 order)"
    jq -r '.jobs["infra-deploy"].if // ""' <<<"$json" | grep -q "database-migration-before-deploy.result == 'success'" ||
      gate_violation "$wf" "job infra-deploy must accept the before-migration only when it succeeded or was skipped (a failed migration means no deploy)"
    jq -r '.jobs["database-migration-before-deploy"].if // ""' <<<"$json" | grep -q "inputs.migrate-before-deploy" ||
      gate_violation "$wf" "job database-migration-before-deploy ignores migrate-before-deploy"
    jq -r '.jobs["database-migration"].if // ""' <<<"$json" | grep -q "!inputs.migrate-before-deploy" ||
      gate_violation "$wf" "job database-migration must be skipped when migrate-before-deploy is true (one migration per run)"
    jq -e '.jobs["database-migration"].needs | index("infra-deploy") != null' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job database-migration must need infra-deploy (P1 order)"
    jq -e '(.jobs["post-deploy"].needs | index("infra-deploy") != null and index("database-migration") != null and index("database-migration-before-deploy") != null)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job post-deploy must need infra-deploy and both migration jobs"
    jq -r '.jobs["post-deploy"].if // ""' <<<"$json" | grep -q "needs.infra-deploy.result == 'success'" ||
      gate_violation "$wf" "job post-deploy must require infra-deploy to succeed"
  done
  gate_finish FLOW-D3
}
