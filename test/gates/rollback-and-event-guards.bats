#!/usr/bin/env bats
# G15/G22 — a workflow that has the `image-tag` input never migrates when it is set (the rollback does not migrate).
# G26 wiring — the gate job calls the validate-inputs composite, which hands it the event and the ref through env:.
#   (The behaviour of validate-inputs.sh itself is covered by test/bats/validate-inputs.bats.)

load 'lib/gates'

@test "G15/G22: database-migration is skipped when image-tag is set (workflows that have the input)" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G15
  local wf json cond job
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '(.on.workflow_call.inputs // {}) | has("image-tag")' <<<"$json" >/dev/null || continue
    while IFS= read -r job; do
      cond="$(jq -r --arg j "$job" '.jobs[$j].if // ""' <<<"$json")"
      [[ $cond =~ image-tag[[:space:]]*==[[:space:]]*\'\' ]] ||
        gate_violation "$wf" "job $job has no condition on image-tag == '' (the rollback must not migrate)"
    done < <(jq -r '.jobs | keys[] | select(startswith("database-migration"))' <<<"$json")
  done
  gate_finish G15
}

@test "G26: the gate job calls validate-inputs and the composite passes EVENT_NAME and REF_NAME through env:" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G26
  local workflows=("${GATE_SUBJECTS[@]}") wf
  for wf in "${workflows[@]}"; do
    gate_json "$wf" | jq -e '[.jobs["quality-and-security-gate"].steps[]?.uses // ""] | any(test("/\\.github/actions/validate-inputs@"))' >/dev/null ||
      gate_violation "$wf" "job quality-and-security-gate does not call the validate-inputs composite"
  done
  local composite=.github/actions/validate-inputs/action.yml
  if [[ -f $GATES_ROOT/$composite ]]; then
    gate_json "$composite" | jq -e '[.runs.steps[]? | select(.run != null) | .env // {}] | any(has("EVENT_NAME") and has("REF_NAME"))' >/dev/null ||
      gate_violation "$composite" "no run step receives EVENT_NAME and REF_NAME through env: (G26/G21 would not see the event)"
  else
    gate_violation "$composite" "the validate-inputs composite does not exist"
  fi
  gate_finish G26
}
