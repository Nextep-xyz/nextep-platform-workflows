#!/usr/bin/env bats
# G16 — database-migration, deploy and infra-deploy serialize per project+environment and never cancel a run in progress.

load 'lib/gates'

@test "G16: deploy-lock-* concurrency groups never cancel in progress" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G16
  local wf json job group cancel found
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    found=0
    while IFS= read -r job; do
      group="$(jq -r --arg j "$job" '.jobs[$j].concurrency | if type == "object" then .group else . end // ""' <<<"$json")"
      cancel="$(jq -r --arg j "$job" '.jobs[$j].concurrency | if type == "object" then (."cancel-in-progress" | tostring) else "absent" end' <<<"$json")"
      case "$job" in
        database-migration | deploy | infra-deploy)
          if [[ $group == deploy-lock-* ]]; then
            found=$((found + 1))
            [[ $cancel == false ]] || gate_violation "$wf" "job '$job': group '$group' must set cancel-in-progress: false (got '$cancel')"
          else
            gate_violation "$wf" "job '$job' must use a 'deploy-lock-<project>-<environment>' concurrency group"
          fi
          ;;
      esac
    done < <(jq -r '.jobs | keys[]' <<<"$json")
    ((found > 0)) || gate_violation "$wf" "no job uses a deploy-lock-* concurrency group"
  done
  gate_finish G16
}
