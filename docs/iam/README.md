# IAM examples (reference, placeholders only)

| File | What it is |
|---|---|
| [`deploy-role-ssm-tunnel-policy.example.json`](deploy-role-ssm-tunnel-policy.example.json) | Minimum permissions the deploy role needs for the SSM-tunnel migration (`SPEC.md §7.1`) |
| [`trust-policy.example.json`](trust-policy.example.json) | Trust policy of the role per (project, environment) |
| [`package-publish-trust-policy.example.json`](package-publish-trust-policy.example.json) | Trust policy of the role that publishes npm packages (`lego-aws-package-publish`): the workflow file by tag and a subject limited to the version tag |
| [`package-publish-policy.example.json`](package-publish-policy.example.json) | Minimum permissions of that role: mint the registry token, resolve one endpoint, publish and describe the packages of one scope |
| [`image-publish-trust-policy.example.json`](image-publish-trust-policy.example.json) | Trust policy of the role that publishes an image (`lego-aws-image-publish`): the workflow file at an EXACT release tag and a subject limited to the version tags of one repository |
| [`image-publish-policy.example.json`](image-publish-policy.example.json) | Minimum permissions of that role: the ECR login token and the push and describe actions on ONE repository. Nothing that deletes, creates or reconfigures |
| [`registry-read-trust-policy.example.json`](registry-read-trust-policy.example.json) | Trust policy of the READ-ONLY role that the gates and deploys use to install private packages (`registry-role-arn`): `lego-aws-cicd` and `lego-aws-environment-deploy` at a release tag, and one repository |
| [`registry-read-policy.example.json`](registry-read-policy.example.json) | Minimum permissions of that role: mint the registry token and read one repository. Nothing that writes |

Replace every `<...>` placeholder. Nothing here is a real account, role or resource.

## Status of the trust policy: NOT VERIFIED

The `job_workflow_ref` condition key is **spike S1** ([ADR 0001](../adr/0001-s1-job-workflow-ref-in-iam.md)) and has not been
tested against a real account. Until it is, treat the `job_workflow_ref` condition as the intended design, not as a
verified control. The `sub` condition is the standard, documented one.

## Rules the example encodes

- One role per (project, environment); the `prod` role is only assumable from `refs/heads/main` (there are no GitHub
  Environments to hold an approval, so the trust policy and the branch ruleset are the barrier).
- The tunnel permissions are scoped to **one** bastion instance and **one** SSM document; the secret and the parameters
  are scoped to the project/stage prefix.
- The role that creates the OIDC role stack is deployed by hand, never from a workflow run that uses it.

## The package publishing role (v1.4.0)

- It is a **separate role** from the deploy roles: it can publish packages and nothing else, and the deploy roles cannot publish.
  One role per (project, package scope) is the natural cut; the policy above scopes the package actions to one repository and one
  namespace (`<NAMESPACE>` is the npm scope without the `@`).
- The barrier is **two things together**: the trust policy (`job_workflow_ref` = the reusable workflow file at a release tag, and a
  `sub` limited to the version tags of the project, `refs/tags/<tag-prefix>*`) and a **tag ruleset** in the consuming repository that lets
  only maintainers create tags with that prefix. Neither alone is enough: a role open to any tag trusts whoever can push one.
- The role holds no delete, copy, dispose or status-update permission: a published version is immutable and is fixed forward
  with a new version.
- The exact set of CodeArtifact actions that `npm publish` and `describe-package-version` need is **NOT VERIFIED**: it comes from
  the AWS documentation and has not been exercised against a real domain. The first integration run in `dev` settles it (runbook section 6).
- The same status as the deploy trust policy applies to `job_workflow_ref` (**NOT VERIFIED**, [ADR 0001](../adr/0001-s1-job-workflow-ref-in-iam.md)).

## The registry read role (v1.5.0)

The gates and the deploys can install private `@scope/*` packages from CodeArtifact (`registry-role-arn`, runbook section 7). That role is **not** the deploy
role and **not** the publishing role.

- **Read-only, and nothing else.** The policy example allows `GetAuthorizationToken` (domain), `sts:GetServiceBearerToken` (only for `codeartifact.amazonaws.com`),
  `GetRepositoryEndpoint` and `ReadFromRepository` (one repository). No `Publish*`, `Put*`, `Delete*`, `Create*`, nothing of `iam:*`. A test pins the exact set of actions.
- **Why this matters more than for the others.** The `quality-and-security-gate` job runs the code of the pull request (lint, tests) with `id-token: write`, because it has to log in
  before it installs. `id-token` belongs to the job, not to the step, so that code could ask for the same OIDC token and assume the same role. The defence is that the role can do
  **nothing but read one repository** and that its trust policy is limited to one repository and to the two deploy-family workflows at a release tag. A pull request from a fork never
  receives `id-token`.
- **The trust policy.** `job_workflow_ref` names `lego-aws-cicd.yml` and `lego-aws-environment-deploy.yml` at a release tag (list `@refs/tags/v1` for the alias or each exact `@refs/tags/vX.Y.Z`
  a caller pins). `sub` is `repo:<org>/<repo>:*`, because the gate also runs on pull requests (`repo:<org>/<repo>:pull_request`) and on branches, so it cannot be narrowed to a tag as the publishing
  role's can. The workflow file is what fences the role; keep the repository variable that holds the role ARN limited to the repositories that need it.
- Same status as the others: the exact action set and `job_workflow_ref` as an IAM condition are **NOT VERIFIED** (runbook section 7.6).

## The image publishing role (v1.6.0)

- **A separate role** from the deploy, registry-read and package-publishing roles: it can push to **one** ECR repository and nothing else. It is created by the owner of the
  repository, **outside the pipeline that uses it** (a pipeline cannot create the role it runs with: one deploy by hand, declared as an exception in the owner's repository).
- **The barrier is two things together**: the trust policy (`job_workflow_ref` = `lego-aws-image-publish.yml` at an EXACT release tag, and a `sub` limited to `refs/tags/<tag-prefix>*` of one
  repository) and a **tag ruleset** in the consuming repository that lets only maintainers create those tags. A role open to any tag trusts whoever can push one.
- **The repository** must have `IMMUTABLE` tags and scan on push; that is what makes the digest of a version final. The role cannot change either setting.
- `ecr:GetAuthorizationToken` is the only action with `Resource: "*"` (ECR has no resource-level scope for it). The set of push actions (`BatchCheckLayerAvailability`, `InitiateLayerUpload`,
  `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`) plus `DescribeImages` and `BatchGetImage` is pinned by a test. **`BatchGetImage` is required** and was found by a first real run: `docker push` (buildx) issues a `HEAD` on the manifest by digest after uploading the layers, and without it the push ends in `403 Forbidden`. The rest of the set still comes from the AWS documentation and is **NOT VERIFIED** beyond that run.
- Same status as the others for `job_workflow_ref` as an IAM condition (**NOT VERIFIED**, [ADR 0001](../adr/0001-s1-job-workflow-ref-in-iam.md)).

## Moving to a new major (`v2.0.0`): update the trust policies FIRST

A trust policy that pins `job_workflow_ref` names the workflow at a tag (`@refs/tags/v1`). A caller that moves to `@v2` presents `@refs/tags/v2`, so with the trust policy not updated its
deploy is **denied**. The order is always: (1) list `@refs/tags/v2` in every role that pins the workflow, **in addition to** `@refs/tags/v1` (never instead: `v1` stays alive for whoever
does not migrate, and adding an entry is reversible); (2) release; (3) change the callers. The examples in this directory list both. The image publishing example pins an exact tag
(`vX.Y.Z`) and is updated with the release that the consumer pins.
