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

# ---- package publishing role (lego-aws-package-publish) -------------------------------------------------------------

@test "the package publishing trust policy pins the workflow file and a tag-scoped subject, never a branch or a bare wildcard" {
  local f="$REPO_ROOT/docs/iam/package-publish-trust-policy.example.json"
  jq -e . "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"' "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:job_workflow_ref"] | (type == "array" or type == "string") and ([.] | flatten | all(test("/\\.github/workflows/lego-aws-package-publish\\.yml@refs/tags/v[0-9]")))' "$f" >/dev/null
  # the subject is the repository at a tag (a prefix + *), not a branch, not a bare repo:*
  jq -e '.Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] | test("^repo:[^*]+:ref:refs/tags/[A-Za-z0-9._-]+\\*$")' "$f" >/dev/null
  ! jq -e '.Statement[0].Condition | .. | strings | select(test("refs/heads/"))' "$f" >/dev/null
}

@test "the package publishing policy has no wildcard action, scopes the package actions to one repository and gates the bearer token to CodeArtifact" {
  local f="$REPO_ROOT/docs/iam/package-publish-policy.example.json"
  jq -e . "$f" >/dev/null
  ! jq -e '.Statement[] | select([.Action] | flatten | any(. == "*" or test(":\*$")))' "$f" >/dev/null
  jq -e '[.Statement[] | select([.Action] | flatten | any(. == "codeartifact:PublishPackageVersion")) | .Resource] | flatten | all(test("^arn:aws:codeartifact:<REGION>:<ACCOUNT>:package/<DOMAIN>/<REPOSITORY>/npm/"))' "$f" >/dev/null
  jq -e '.Statement[] | select([.Action] | flatten | any(. == "sts:GetServiceBearerToken")) | .Condition.StringEquals["sts:AWSServiceName"] == "codeartifact.amazonaws.com"' "$f" >/dev/null
  # the role can publish and describe; it cannot delete, copy or dispose of versions
  ! jq -e '.Statement[] | select([.Action] | flatten | any(test("Delete|Dispose|Copy|UpdatePackageVersionsStatus|Associate|Create")))' "$f" >/dev/null
}
