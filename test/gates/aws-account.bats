#!/usr/bin/env bats
# GH5 — the AWS account id is never an input and never a literal: the workflow derives it from the assumed role
# (SPEC P2 D9). Subjects: every contract, every lego workflow and every composite, discovered on disk.

load 'lib/gates'

@test "GH5: no input carries the account id and no AWS_ACCOUNT_ID is assigned a literal" {
  gate_require_tools yq jq
  gate_discover GH5 contracts .github/workflows .github/actions -type f '(' -name '*.contract.yml' -o -name 'lego-*.yml' -o -name 'action.yml' ')'
  local f line
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r line; do
      gate_violation "$f" "input '$line' looks like an account id: the account comes from the assumed role (sts get-caller-identity), never from the caller"
    done < <(gate_json "$f" | jq -r '[(.inputs // {}), (.on.workflow_call.inputs // {})] | .[] | keys[] | select(test("account"; "i"))')
    while IFS= read -r line; do
      gate_violation "$f" "AWS_ACCOUNT_ID is assigned a literal (${line})"
    done < <(grep -nE 'AWS_ACCOUNT_ID["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]$"'"'"'{(]' "$GATES_ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done
  gate_finish GH5
}
