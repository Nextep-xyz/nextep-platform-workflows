#!/usr/bin/env bats
# G-DB2 — the database stage can be switched off with `migrate: false` (sibling of static-compute.bats). Discovered from
# disk: in every workflow that has the migrate-before-deploy input, EVERY piece of the stage honours `inputs.migrate`:
#   the tunnel step and the migrate step of infra-deploy, the database-migration job and the separate post-deploy job
#   (positive condition), and the post-deploy step of infra-deploy (which must run there when the stage is off).
# `inputs.migrate-before-deploy` shares the prefix: the patterns exclude it.
# G-DB3 — the contract declares migrate as a boolean whose default is true (no existing caller changes behaviour).

load 'lib/gates'

positive='(^|[^!A-Za-z0-9_.-])inputs\.migrate([^A-Za-z0-9_-]|$)'
negative='!inputs\.migrate([^A-Za-z0-9_-]|$)'

@test "G-DB2: every piece of the database stage honours inputs.migrate" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G-DB2
  local wf json found=0 pieces cond n
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.on.workflow_call.inputs | has("migrate-before-deploy")' <<<"$json" >/dev/null || continue
    found=$((found + 1))
    jq -e '.on.workflow_call.inputs | has("migrate")' <<<"$json" >/dev/null ||
      gate_violation "$wf" "the workflow has migrate-before-deploy but no migrate input"
    cond="$(jq -r '.jobs["database-migration"].if // ""' <<<"$json")"
    grep -Eq -- "$positive" <<<"$cond" ||
      gate_violation "$wf" "job database-migration does not honour inputs.migrate (if: ${cond:-<none>})"
    cond="$(jq -r '.jobs["post-deploy"].if // ""' <<<"$json")"
    grep -Eq -- "$positive" <<<"$cond" ||
      gate_violation "$wf" "job post-deploy (the one that waits for the migration) does not honour inputs.migrate (if: ${cond:-<none>})"
    pieces="$(jq -r '.jobs["infra-deploy"].steps[] | select((.uses // "") | test("/actions/(ssm-tunnel|migrate)@")) | (.if // "")' <<<"$json")"
    n="$(grep -c '' <<<"$pieces" || true)"
    ((n >= 2)) || gate_violation "$wf" "expected the tunnel and migrate steps of infra-deploy, found $n (the gate does not recognise the workflow shape)"
    while IFS= read -r cond; do
      grep -Eq -- "$positive" <<<"$cond" ||
        gate_violation "$wf" "a tunnel/migrate step of infra-deploy does not honour inputs.migrate (if: ${cond:-<none>})"
    done <<<"$pieces"
    cond="$(jq -r '.jobs["infra-deploy"].steps[] | select((.uses // "") | test("/actions/post-deploy@")) | (.if // "")' <<<"$json")"
    grep -Eq -- "$negative" <<<"$cond" ||
      gate_violation "$wf" "the post-deploy step of infra-deploy does not run when the stage is off, it lacks !inputs.migrate (if: ${cond:-<none>})"
  done
  ((found > 0)) || gate_fail "G-DB2: no workflow with the migrate-before-deploy input was found (a gate that finds nothing proves nothing)"
  gate_finish G-DB2
}

@test "G-DB3: migrate is a boolean that defaults to true in the workflow and in its contract" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G-DB3
  local wf json found=0 name contract
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.on.workflow_call.inputs | has("migrate-before-deploy")' <<<"$json" >/dev/null || continue
    found=$((found + 1))
    name="$(basename "$wf" .yml)"
    contract="contracts/$name.contract.yml"
    jq -e '.on.workflow_call.inputs.migrate | .type == "boolean" and .default == true' <<<"$json" >/dev/null ||
      gate_violation "$wf" "input migrate must be type boolean with default true"
    if [[ ! -f $GATES_ROOT/$contract ]]; then
      gate_violation "$wf" "has no contract ($contract)"
      continue
    fi
    gate_json "$contract" | jq -e '.inputs.migrate | .type == "boolean" and .default == true' >/dev/null ||
      gate_violation "$contract" "input migrate must be type boolean with default true"
  done
  ((found > 0)) || gate_fail "G-DB3: no workflow with the migrate-before-deploy input was found (a gate that finds nothing proves nothing)"
  gate_finish G-DB3
}
