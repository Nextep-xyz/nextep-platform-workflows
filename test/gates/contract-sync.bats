#!/usr/bin/env bats
# G12 — every .github/workflows/lego-aws-*.yml matches contracts/<name>.contract.yml:
# inputs (type, required, default), secrets, outputs and the `name:` of its jobs. Also: no contract without workflow.

load 'lib/gates'

@test "G12: each reusable workflow matches its contract (inputs, secrets, outputs, job names)" {
  gate_require_tools yq jq
  gate_discover G12 contracts -maxdepth 1 -type f -name '*.contract.yml'
  local contracts=("${GATE_SUBJECTS[@]}")
  gate_discover_lego_workflows G12

  local wf name contract want got diff
  for wf in "${GATE_SUBJECTS[@]}"; do
    name="$(basename "$wf" .yml)"
    contract="contracts/$name.contract.yml"
    if [[ ! -f $GATES_ROOT/$contract ]]; then
      gate_violation "$wf" "has no contract ($contract)"
      continue
    fi

    want="$(gate_json "$contract" | jq -S '.inputs // {} | map_values({type: .type, required: (.required // false), default: (.default // null)})')"
    got="$(gate_workflow_inputs_json "$wf")"
    diff="$(jq -rn --argjson w "$want" --argjson g "$got" '
      (([$w | keys[]] - [$g | keys[]]) | map("input missing in the workflow: " + .)) +
      (([$g | keys[]] - [$w | keys[]]) | map("input not in the contract: " + .)) +
      ([$w | keys[] | select($g[.] != null and $g[.] != $w[.])] | map("input differs from the contract: " + .)) | join("; ")')"
    [[ -z $diff ]] || gate_violation "$wf" "$diff"

    want="$(gate_json "$contract" | jq -cS '.secrets // {} | map_values({required: (.required // false)})')"
    got="$(gate_json "$wf" | jq -cS '.on.workflow_call.secrets // {} | map_values({required: (.required // false)})')"
    [[ $want == "$got" ]] || gate_violation "$wf" "secrets differ from the contract (workflow: $got, contract: $want)"

    want="$(gate_json "$contract" | jq -cS '.outputs // {} | keys')"
    got="$(gate_json "$wf" | jq -cS '.on.workflow_call.outputs // {} | keys')"
    [[ $want == "$got" ]] || gate_violation "$wf" "outputs differ from the contract (workflow: $got, contract: $want)"

    want="$(gate_json "$contract" | jq -cS '.jobs // [] | sort')"
    got="$(gate_json "$wf" | jq -cS '.jobs | to_entries | map(.value.name // .key) | sort')"
    [[ $want == "$got" ]] || gate_violation "$wf" "job names differ from the contract (workflow: $got, contract: $want)"
  done

  local c
  for c in "${contracts[@]}"; do
    name="$(basename "$c" .contract.yml)"
    [[ -f $GATES_ROOT/.github/workflows/$name.yml ]] || gate_violation "$c" "contract without a workflow (.github/workflows/$name.yml)"
  done
  gate_finish G12
}
