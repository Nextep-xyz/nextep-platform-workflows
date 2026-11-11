#!/usr/bin/env bats
# compute: static (a single-page app on object storage + CDN) has no image and no database stage.
# Two invariants, both discovered from disk:
#   1. every value of `compute` that validate-inputs.sh accepts has a sandbox caller (a value without an example caller is
#      a value nobody ever exercised);
#   2. in every workflow that can run a database stage ahead of or after the deploy, each piece of that stage is switched
#      off for static (the job, the tunnel and migrate steps, the separate post-deploy job).

load 'lib/gates'

@test "every value of compute accepted by validate-inputs.sh has a sandbox caller" {
  gate_discover G-COMPUTE scripts -maxdepth 1 -type f -name validate-inputs.sh
  local validator="${GATE_SUBJECTS[0]}" line values v n=0
  line="$(grep -E '^case "\$compute" in ' "$GATES_ROOT/$validator" | head -1 || true)"
  values="$(sed -nE 's/^case "\$compute" in ([a-z |]+)\) ;;.*/\1/p' <<<"$line" | tr '|' ' ')"
  for v in $values; do n=$((n + 1)); done
  ((n > 0)) || gate_fail "G-COMPUTE: no accepted compute values parsed from $validator (the enum line changed shape: fix the gate, not the check)"
  gate_discover G-COMPUTE test/sandbox/callers -type f -name '*.yml'
  for v in $values; do
    grep -qE "^[[:space:]]+compute: $v[[:space:]]*$" "${GATE_SUBJECTS[@]/#/$GATES_ROOT/}" ||
      gate_violation "$validator" "compute '$v' is accepted but no caller in test/sandbox/callers uses it"
  done
  gate_finish G-COMPUTE
}

@test "compute static switches off every piece of the database stage in the workflows that have one" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G-STATIC-DB
  local wf json found=0 pieces cond n
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.on.workflow_call.inputs | has("migrate-before-deploy")' <<<"$json" >/dev/null || continue
    found=$((found + 1))
    cond="$(jq -r '.jobs["database-migration"].if // ""' <<<"$json")"
    [[ $cond == *"inputs.compute != 'static'"* ]] ||
      gate_violation "$wf" "job database-migration is not switched off for compute=static"
    cond="$(jq -r '.jobs["post-deploy"].if // ""' <<<"$json")"
    [[ $cond == *"inputs.compute != 'static'"* ]] ||
      gate_violation "$wf" "job post-deploy (the one that waits for the migration) is not switched off for compute=static"
    pieces="$(jq -r '.jobs["infra-deploy"].steps[] | select((.uses // "") | test("/actions/(ssm-tunnel|migrate)@")) | (.if // "")' <<<"$json")"
    n="$(grep -c '' <<<"$pieces" || true)"
    ((n >= 2)) || gate_violation "$wf" "expected the tunnel and migrate steps of infra-deploy, found $n (the gate does not recognise the workflow shape)"
    while IFS= read -r cond; do
      [[ $cond == *"inputs.compute != 'static'"* ]] ||
        gate_violation "$wf" "a tunnel/migrate step of infra-deploy is not switched off for compute=static (if: ${cond:-<none>})"
    done <<<"$pieces"
  done
  ((found > 0)) || gate_fail "G-STATIC-DB: no workflow with the migrate-before-deploy input was found (a gate that finds nothing proves nothing)"
  gate_finish G-STATIC-DB
}
