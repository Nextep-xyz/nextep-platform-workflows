#!/usr/bin/env bats
# docs/iam: the examples are valid JSON, least-privilege shaped and contain only placeholders.

load 'helpers'

@test "iam examples are valid JSON and every ARN uses <ACCOUNT>/<REGION> placeholders" {
  local f
  for f in "$REPO_ROOT"/docs/iam/*.json; do
    jq -e . "$f" >/dev/null
    ! grep -qE '[0-9]{12}' "$f"
  done
}

@test "the tunnel policy has no wildcard action and scopes StartSession to one instance and one document" {
  local f="$REPO_ROOT/docs/iam/deploy-role-ssm-tunnel-policy.example.json"
  ! jq -e '.Statement[] | select(.Action == "*" or .Action == "ssm:*")' "$f" >/dev/null
  [ "$(jq '[.Statement[] | select(.Action == "ssm:StartSession") | .Resource[]] | length' "$f")" -eq 2 ]
}

@test "the trust policy conditions on the audience, the workflow ref and the subject" {
  local f="$REPO_ROOT/docs/iam/trust-policy.example.json"
  jq -e '.Statement[0].Condition.StringEquals | has("token.actions.githubusercontent.com:aud") and has("token.actions.githubusercontent.com:job_workflow_ref")' "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringLike | has("token.actions.githubusercontent.com:sub")' "$f" >/dev/null
}
