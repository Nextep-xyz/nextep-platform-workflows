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

# ---- registry read role (the OIDC login of setup-project, v1.5.0) --------------------------------------------------------------

@test "the registry read policy allows exactly the four read actions, scopes them to one repository and gates the bearer token to CodeArtifact" {
  local f="$REPO_ROOT/docs/iam/registry-read-policy.example.json"
  jq -e . "$f" >/dev/null
  # the whole set of actions, nothing else: a new action in the example is a decision a test has to know about
  [ "$(jq -c '[.Statement[] | .Action] | flatten | sort' "$f")" = '["codeartifact:GetAuthorizationToken","codeartifact:GetRepositoryEndpoint","codeartifact:ReadFromRepository","sts:GetServiceBearerToken"]' ]
  # read-only: no publish, no put, no delete, no copy, no create, no dispose, nothing of IAM, no wildcard action
  ! jq -e '.Statement[] | select([.Action] | flatten | any(test("Publish|Put|Delete|Dispose|Copy|Create|Update|Associate|Disassociate|^iam:|:\\*$") or . == "*"))' "$f" >/dev/null
  jq -e '[.Statement[] | select(.Effect != "Allow")] | length == 0' "$f" >/dev/null
  jq -e '[.Statement[] | select([.Action] | flatten | any(. == "codeartifact:GetRepositoryEndpoint" or . == "codeartifact:ReadFromRepository")) | .Resource] | flatten | all(test("^arn:aws:codeartifact:<REGION>:<ACCOUNT>:repository/<DOMAIN>/<REPOSITORY>$"))' "$f" >/dev/null
  jq -e '.Statement[] | select([.Action] | flatten | any(. == "sts:GetServiceBearerToken")) | .Condition.StringEquals["sts:AWSServiceName"] == "codeartifact.amazonaws.com"' "$f" >/dev/null
}

@test "the registry read trust policy pins the two deploy-family workflows at a tag and a subject limited to one repository, never a bare wildcard" {
  local f="$REPO_ROOT/docs/iam/registry-read-trust-policy.example.json"
  jq -e . "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"' "$f" >/dev/null
  # job_workflow_ref: only lego-aws-cicd and lego-aws-environment-deploy, each at a release tag, never a branch (the gate job runs inside them)
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:job_workflow_ref"] | (type == "array") and length > 0 and all(test("/\\.github/workflows/lego-aws-(cicd|environment-deploy)\\.yml@refs/tags/v[0-9]"))' "$f" >/dev/null
  # sub: the repository (owner/name, no wildcard in them) and then anything: a pull request, a branch. job_workflow_ref is what fences the workflow
  jq -e '.Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] | test("^repo:[^*:/]+/[^*:/]+:[^:]*\\*?$") and (test("^repo:\\*") | not)' "$f" >/dev/null
  # the role of the registry is not the role of the deploy: it cannot be assumed for anything but the read
  ! jq -e '.Statement[0].Condition | .. | strings | select(test("lego-aws-package-"))' "$f" >/dev/null
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

# ---- image publishing role (lego-aws-image-publish) -----------------------------------------------------------------------

@test "the image publishing trust policy pins the workflow file at an exact tag and a tag-scoped subject, never a branch or a bare wildcard" {
  local f="$REPO_ROOT/docs/iam/image-publish-trust-policy.example.json"
  jq -e . "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"' "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:job_workflow_ref"] | (type == "array" or type == "string") and ([.] | flatten | all(test("/\\.github/workflows/lego-aws-image-publish\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$")))' "$f" >/dev/null
  jq -e '.Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] | test("^repo:[^*]+:ref:refs/tags/[A-Za-z0-9._-]+\\*$")' "$f" >/dev/null
  ! jq -e '.Statement[0].Condition | .. | strings | select(test("refs/heads/"))' "$f" >/dev/null
  # it is not the role of a package or a deploy workflow
  ! jq -e '.Statement[0].Condition | .. | strings | select(test("lego-aws-(package-|cicd|environment-deploy)"))' "$f" >/dev/null
}

@test "the image publishing policy allows exactly the push actions, scopes them to one repository and cannot delete, create or reconfigure anything" {
  local f="$REPO_ROOT/docs/iam/image-publish-policy.example.json"
  jq -e . "$f" >/dev/null
  # the whole set, nothing else: a new action in the example is a decision a test has to know about
  [ "$(jq -c '[.Statement[] | .Action] | flatten | sort' "$f")" = '["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:CompleteLayerUpload","ecr:DescribeImages","ecr:GetAuthorizationToken","ecr:InitiateLayerUpload","ecr:PutImage","ecr:UploadLayerPart"]' ]
  ! jq -e '.Statement[] | select([.Action] | flatten | any(. == "*" or test(":\\*$")))' "$f" >/dev/null
  ! jq -e '.Statement[] | select([.Action] | flatten | any(test("Delete|Create|SetRepositoryPolicy|PutLifecycle|PutImageTagMutability|PutRegistry|Replication|GetDownloadUrlForLayer")))' "$f" >/dev/null
  jq -e '[.Statement[] | select(.Effect != "Allow")] | length == 0' "$f" >/dev/null
  # only GetAuthorizationToken may use Resource "*" (ECR has no resource-level scope for it); every other action names ONE repository
  jq -e '[.Statement[] | select([.Action] | flatten | any(. == "ecr:GetAuthorizationToken") | not) | .Resource] | flatten | all(test("^arn:aws:ecr:<REGION>:<ACCOUNT>:repository/<REPOSITORY>$"))' "$f" >/dev/null
  jq -e '[.Statement[] | select([.Action] | flatten | any(. == "ecr:GetAuthorizationToken")) | .Action] | flatten == ["ecr:GetAuthorizationToken"]' "$f" >/dev/null
}
