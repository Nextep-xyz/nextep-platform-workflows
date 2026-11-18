#!/usr/bin/env bats
# G2 — least privilege: no workflow-level permissions, every job declares its own,
# `id-token: write` only in the jobs that assume the role (migration, deploy, infra-deploy, post-deploy), in the telemetry job
# with exact permissions (amendment of SPEC telemetria-dora 3.2), in `publish` of the package family (exact permissions too) and,
# with the conditions of the v1.5.0 amendment, in the quality-and-security-gate of the deploy family (registry login, read-only role);
# no `contents: write`.

load 'lib/gates'

@test "G2: permissions are declared per job and id-token: write is confined to the jobs that assume the role" {
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
        database-migration | deploy | infra-deploy | post-deploy) ;;
        # Package family: `publish` assumes the publishing role. Allowed ONLY in lego-aws-package-*.yml and with exactly
        # {contents: read, id-token: write} (it needs nothing else: no pull-requests, no writes).
        publish)
          [[ $(basename "$wf") == lego-aws-package-* ]] ||
            gate_violation "$wf" "job 'publish' has 'id-token: write' but this is not a package workflow (lego-aws-package-*.yml)"
          jq -e '.jobs["publish"].permissions == {"contents": "read", "id-token": "write"}' <<<"$json" >/dev/null ||
            gate_violation "$wf" "job 'publish' may hold id-token: write only with exactly {contents: read, id-token: write} (got $(jq -c '.jobs["publish"].permissions' <<<"$json"))"
          ;;
        # G2 amendment (v1.5.0, SPEC section 0 "Enmienda Login del registry"): the quality-and-security-gate job of the DEPLOY family may
        # hold id-token: write so that setup-project can log in to the registry with a READ-ONLY role and install private packages. It is
        # not relaxed in general: exactly {contents: read, pull-requests: write (optional), id-token: write}; no step that assumes a
        # deploy role or deploys; and every setup-project step takes registry-role-arn from the workflow input (the permission exists
        # for that login and for nothing else). The trust policy of that role (repository + job_workflow_ref) is checked in iam-docs.bats.
        quality-and-security-gate)
          if [[ $(basename "$wf") == lego-aws-package-* ]]; then
            gate_violation "$wf" "job 'quality-and-security-gate' has 'id-token: write' but the gate of a package workflow holds no cloud credentials (GR-F1)"
            continue
          fi
          jq -e '.jobs["quality-and-security-gate"].permissions | ((keys - ["contents", "pull-requests", "id-token"]) | length == 0) and .contents == "read" and ((.["pull-requests"] // "write") == "write")' <<<"$json" >/dev/null ||
            gate_violation "$wf" "job 'quality-and-security-gate' has 'id-token: write' but its permissions are not exactly {contents: read, pull-requests: write (optional), id-token: write} (got $(jq -c '.jobs["quality-and-security-gate"].permissions' <<<"$json"))"
          jq -e '[.jobs["quality-and-security-gate"].steps[]? | select((.uses // "") | test("/actions/(aws-oidc|infra-deploy|deploy-ecs|deploy-lambda|migrate|ssm-tunnel|post-deploy|telemetry)@"))] | length == 0' <<<"$json" >/dev/null ||
            gate_violation "$wf" "job 'quality-and-security-gate' has 'id-token: write' but uses a composite that assumes a deploy role or deploys: the gate only ever holds the read-only registry role"
          jq -e --arg want '${{ inputs.registry-role-arn }}' '[.jobs["quality-and-security-gate"].steps[]? | select((.uses // "") | test("/actions/setup-project@"))] | (length > 0) and all(.with["registry-role-arn"] == $want)' <<<"$json" >/dev/null ||
            gate_violation "$wf" "job 'quality-and-security-gate' has 'id-token: write' but its setup-project step does not take registry-role-arn from the workflow input: the permission exists only for the registry login"
          ;;
        # G2 amendment (SPEC telemetria-dora 3.2): the telemetry job asks for an id-token to mint a token for the collector
        # (never for a cloud). It is allowed ONLY with exactly {contents: read, id-token: write}; G17/T8 fence what it runs.
        telemetry-phone-home)
          jq -e '.jobs["telemetry-phone-home"].permissions == {"contents": "read", "id-token": "write"}' <<<"$json" >/dev/null ||
            gate_violation "$wf" "job 'telemetry-phone-home' may hold id-token: write only with exactly {contents: read, id-token: write} (got $(jq -c '.jobs["telemetry-phone-home"].permissions' <<<"$json"))"
          ;;
        *) gate_violation "$wf" "job '$job' has 'id-token: write'; only the migration, deploy, infra-deploy and post-deploy jobs (telemetry-phone-home, publish in a package workflow and the registry-login gate job, with exact permissions) may" ;;
      esac
    done < <(jq -r '.jobs | to_entries[] | select(.value.permissions["id-token"]? == "write") | .key' <<<"$json")
    while IFS= read -r job; do
      gate_violation "$wf" "job '$job' grants write-all/read-all or contents: write"
    done < <(jq -r '.jobs | to_entries[] | select(.value.permissions == "write-all" or .value.permissions == "read-all" or .value.permissions.contents? == "write") | .key' <<<"$json")
  done
  gate_finish G2
}
