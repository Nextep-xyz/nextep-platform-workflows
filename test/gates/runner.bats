#!/usr/bin/env bats
# G23 — everything runs on ubuntu-latest (GitHub-hosted) and no `runner` input exists (P1-D12).
# G10 — no input weakens or skips the gate.

load 'lib/gates'

@test "G23: every job runs on ubuntu-latest and no 'runner' input exists in workflows or contracts" {
  gate_require_tools yq jq
  gate_discover G23 contracts -maxdepth 1 -type f -name '*.contract.yml'
  local contracts=("${GATE_SUBJECTS[@]}") c wf job
  gate_discover_lego_workflows G23
  for wf in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r job; do
      gate_violation "$wf" "job '$job' does not run on ubuntu-latest"
    done < <(gate_json "$wf" | jq -r '.jobs | to_entries[] | select((.value["runs-on"] // "") != "ubuntu-latest") | .key')
    gate_json "$wf" | jq -e '(.on.workflow_call.inputs // {}) | has("runner") | not' >/dev/null ||
      gate_violation "$wf" "has an input named 'runner' (removed by P1-D12)"
  done
  for c in "${contracts[@]}"; do
    gate_json "$c" | jq -e '(.inputs // {}) | has("runner") | not' >/dev/null ||
      gate_violation "$c" "declares an input named 'runner' (removed by P1-D12)"
  done
  gate_finish G23
}

@test "G10: no contract input skips, disables or relaxes a gate or a scan" {
  gate_require_tools yq jq
  gate_discover G10 contracts -maxdepth 1 -type f -name '*.contract.yml'
  local c name
  for c in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r name; do
      gate_violation "$c" "input '$name' would weaken or skip a gate"
    done < <(gate_json "$c" | jq -r '(.inputs // {}) | keys[] | select(test("^(skip|disable|no)-|-scan$|^trivy-severity$|insecure"))')
  done
  gate_finish G10
}
