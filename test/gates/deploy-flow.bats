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

@test "P2 D3: migrate-before-deploy folds the migration and post-deploy into infra-deploy as steps (no extra runners); false keeps infra -> migration -> post-deploy as jobs" {
  gate_require_tools yq jq
  gate_discover_lego_workflows FLOW-D3
  local wf json
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '(.on.workflow_call.inputs // {}) | has("migrate-before-deploy")' <<<"$json" >/dev/null || continue

    # Runner budget: the "migrate first" order must not cost a runner per phase.
    jq -e '.jobs | has("database-migration-before-deploy") | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job database-migration-before-deploy must not exist: with migrate-before-deploy the migration is a step of infra-deploy (one runner fewer, one install fewer)"
    jq -e '.jobs["infra-deploy"].needs == ["quality-and-security-gate"]' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job infra-deploy must need only quality-and-security-gate (a failed gate means no migration and no deploy)"
    jq -e '(.jobs["infra-deploy"].if // "") == ""' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job infra-deploy must not carry an if: it runs whenever the gate succeeded"

    # Order inside infra-deploy: role -> [tunnel] -> migrate -> infrastructure -> post-deploy; a step failure stops the job.
    jq -e '[.jobs["infra-deploy"].steps[] | .uses // ""] as $u
      | ($u | map(test("/actions/aws-oidc@")) | index(true)) as $o
      | ($u | map(test("/actions/migrate@")) | index(true)) as $m
      | ($u | map(test("/actions/infra-deploy@")) | index(true)) as $i
      | ($u | map(test("/actions/post-deploy@")) | index(true)) as $p
      | $o != null and $m != null and $i != null and $p != null and $o < $m and $m < $i and $i < $p' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job infra-deploy must run aws-oidc, then migrate, then infra-deploy, then post-deploy (migration before the infrastructure)"
    jq -e '.jobs["infra-deploy"].steps[] | select((.uses // "") | test("/actions/migrate@")) | .if // ""' <<<"$json" |
      grep -q "inputs.migrate-before-deploy" ||
      gate_violation "$wf" "the migrate step of infra-deploy ignores migrate-before-deploy (two migrations in one run)"
    jq -e '.jobs["infra-deploy"].steps[] | select((.uses // "") | test("/actions/migrate@")) | .if // ""' <<<"$json" |
      grep -q "inputs.image-tag == ''" ||
      gate_violation "$wf" "the migrate step of infra-deploy must be skipped on rollback (image-tag set): a rollback never migrates"
    jq -r '.jobs["infra-deploy"].steps[] | select(.id == "tunnel") | .if // ""' <<<"$json" | grep -q "inputs.db-access == 'ssm-tunnel'" ||
      gate_violation "$wf" "the tunnel step of infra-deploy must run only when db-access=ssm-tunnel"
    jq -r '.jobs["infra-deploy"].steps[] | select((.uses // "") | test("/actions/post-deploy@")) | .if // ""' <<<"$json" |
      grep -q "inputs.migrate-before-deploy && inputs.post-deploy-command != ''" ||
      gate_violation "$wf" "the post-deploy step of infra-deploy must run only with migrate-before-deploy and a post-deploy-command"

    # The other order (infrastructure -> migration -> post-deploy) keeps its jobs, each waiting for the previous one.
    jq -r '.jobs["database-migration"].if // ""' <<<"$json" | grep -q "!inputs.migrate-before-deploy" ||
      gate_violation "$wf" "job database-migration must be skipped when migrate-before-deploy is true (one migration per run)"
    jq -e '.jobs["database-migration"].needs | index("infra-deploy") != null' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job database-migration must need infra-deploy (P1 order)"
    jq -e '(.jobs["post-deploy"].needs | index("infra-deploy") != null and index("database-migration") != null)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job post-deploy must need infra-deploy and database-migration"
    jq -r '.jobs["post-deploy"].if // ""' <<<"$json" | grep -q "needs.infra-deploy.result == 'success'" ||
      gate_violation "$wf" "job post-deploy must require infra-deploy to succeed"
    jq -r '.jobs["post-deploy"].if // ""' <<<"$json" | grep -q "needs.database-migration.result == 'success'" ||
      gate_violation "$wf" "job post-deploy must accept the migration only when it succeeded or was skipped (a failed migration means no post-deploy)"
    jq -r '.jobs["post-deploy"].if // ""' <<<"$json" | grep -q "!inputs.migrate-before-deploy" ||
      gate_violation "$wf" "job post-deploy must be skipped when migrate-before-deploy is true (the step of infra-deploy already ran it)"
  done
  gate_finish FLOW-D3
}
