#!/usr/bin/env bats
# G5 (and G24) — no `${{ inputs.* }}`, `${{ github.event.* }}`, `${{ github.ref_name }}`, `${{ github.head_ref }}`
# or `${{ secrets.* }}` inside `run:`. Everything goes through `env:`. Command inputs are covered by this gate.

load 'lib/gates'

@test "G5: no untrusted expression is interpolated inside a run: block (workflows and composites)" {
  gate_require_tools yq jq
  gate_discover G5 .github -type f '(' -name '*.yml' -o -name '*.yaml' ')'
  local f line n
  local re='\$\{\{[^}]*(inputs\.|github\.event\.|github\.ref_name|github\.head_ref|secrets\.)'
  for f in "${GATE_SUBJECTS[@]}"; do
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      if [[ $line =~ $re ]]; then
        gate_violation "$f" "run: step #$n interpolates an expression; pass it through env: instead"
      fi
    done < <(gate_json "$f" | jq -c '[(.jobs // {} | .[] | ((.steps // [])[] | .run)), ((.runs.steps // [])[] | .run)] | .[] | select(. != null)')
  done
  gate_finish G5
}
