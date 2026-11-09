#!/usr/bin/env bats
# G18 — parity matrix (docs/parity/matrix.yml) <-> tree.

load 'lib/gates'

@test "G18: the parity matrix and the '# parity: <id>' tags in the tree agree" {
  gate_require_tools yq jq
  local matrix=docs/parity/matrix.yml
  gate_discover G18 docs/parity -maxdepth 1 -type f -name 'matrix.yml'
  local m_json
  m_json="$(gate_json "$matrix")"
  local ids
  mapfile -t ids < <(jq -r '.parity[]?.id' <<<"$m_json")
  ((${#ids[@]} > 0)) || { gate_fail "G18: the matrix lists no ids"; return 1; }

  # tags found in the tree (workflows, composites, scripts)
  local tagged tag
  tagged="$(cd "$GATES_ROOT" && grep -rhoE '#[[:space:]]*parity:[[:space:]]*P-[A-Z]{2}-[0-9]{2}([[:space:],]+P-[A-Z]{2}-[0-9]{2})*' .github scripts 2>/dev/null | grep -oE 'P-[A-Z]{2}-[0-9]{2}' | sort -u || true)"
  for tag in $tagged; do
    jq -e --arg id "$tag" '[.parity[].id] | index($id) != null' <<<"$m_json" >/dev/null ||
      gate_violation "$matrix" "tag '# parity: $tag' in the tree is not in the matrix"
  done

  local id flow status n_inputs reason inp contract
  for id in "${ids[@]}"; do
    flow="$(jq -r --arg id "$id" '.parity[] | select(.id == $id) | .flow' <<<"$m_json")"
    status="$(jq -r --arg id "$id" '.parity[] | select(.id == $id) | .status' <<<"$m_json")"
    case "$flow" in
      cicd) contract="contracts/lego-aws-cicd.contract.yml" ;;
      environment-deploy) contract="contracts/lego-aws-environment-deploy.contract.yml" ;;
      *) gate_violation "$matrix" "$id: flow must be cicd or environment-deploy (got '$flow')"; continue ;;
    esac
    case "$status" in
      covered)
        n_inputs="$(jq -r --arg id "$id" '.parity[] | select(.id == $id) | (.inputs // []) | length' <<<"$m_json")"
        ((n_inputs > 0)) || gate_violation "$matrix" "$id: covered but lists no inputs"
        while IFS= read -r inp; do
          [[ -f $GATES_ROOT/$contract ]] && gate_json "$contract" | jq -e --arg i "$inp" '.inputs | has($i)' >/dev/null ||
            gate_violation "$matrix" "$id: input '$inp' does not exist in $contract"
        done < <(jq -r --arg id "$id" '.parity[] | select(.id == $id) | (.inputs // [])[]' <<<"$m_json")
        # once the workflow of the flow exists, the id must be tagged in the tree
        if [[ -f $GATES_ROOT/.github/workflows/lego-aws-$flow.yml ]]; then
          grep -qx "$id" <<<"$tagged" || gate_violation "$matrix" "$id: covered but no '# parity: $id' tag exists in .github/ or scripts/"
        fi
        ;;
      discarded)
        reason="$(jq -r --arg id "$id" '.parity[] | select(.id == $id) | .reason // ""' <<<"$m_json")"
        [[ -n $reason ]] || gate_violation "$matrix" "$id: discarded without a reason"
        ;;
      *) gate_violation "$matrix" "$id: status must be covered or discarded (got '$status')" ;;
    esac
  done
  gate_finish G18
}

@test "G18: every lego-aws workflow carries parity tags" {
  gate_discover_lego_workflows G18
  local wf
  for wf in "${GATE_SUBJECTS[@]}"; do
    grep -qE '#[[:space:]]*parity:[[:space:]]*P-' "$GATES_ROOT/$wf" || gate_violation "$wf" "no '# parity: <id>' tag in the workflow"
  done
  gate_finish G18
}
