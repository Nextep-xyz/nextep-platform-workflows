#!/usr/bin/env bats
# G2 — least privilege: no workflow-level permissions, every job declares its own,
# `id-token: write` only in database-migration, deploy and infra-deploy; no `contents: write`.

load 'lib/gates'

@test "G2: permissions are declared per job and id-token: write is confined to migration/deploy/infra-deploy" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G2
  local wf json job
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.permissions == null' <<<"$json" >/dev/null ||
      gate_violation "$wf" "workflow-level 'permissions:' is forbidden; declare them per job"
    while IFS= read -r job; do
      jq -e --arg j "$job" '.jobs[$j].permissions != null' <<<"$json" >/dev/null ||
        gate_violation "$wf" "job '$job' does not declare 'permissions:'"
    done < <(jq -r '.jobs | keys[]' <<<"$json")
    while IFS= read -r job; do
      case "$job" in
        database-migration | deploy | infra-deploy) ;;
        *) gate_violation "$wf" "job '$job' has 'id-token: write'; only database-migration, deploy and infra-deploy may" ;;
      esac
    done < <(jq -r '.jobs | to_entries[] | select(.value.permissions["id-token"]? == "write") | .key' <<<"$json")
    while IFS= read -r job; do
      gate_violation "$wf" "job '$job' grants write-all/read-all or contents: write"
    done < <(jq -r '.jobs | to_entries[] | select(.value.permissions == "write-all" or .value.permissions == "read-all" or .value.permissions.contents? == "write") | .key' <<<"$json")
  done
  gate_finish G2
}
