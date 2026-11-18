# IAM examples (reference, placeholders only)

| File | What it is |
|---|---|
| [`deploy-role-ssm-tunnel-policy.example.json`](deploy-role-ssm-tunnel-policy.example.json) | Minimum permissions the deploy role needs for the SSM-tunnel migration (`SPEC.md §7.1`) |
| [`trust-policy.example.json`](trust-policy.example.json) | Trust policy of the role per (project, environment) |
| [`package-publish-trust-policy.example.json`](package-publish-trust-policy.example.json) | Trust policy of the role that publishes npm packages (`lego-aws-package-publish`): the workflow file by tag and a subject limited to the version tag |
| [`package-publish-policy.example.json`](package-publish-policy.example.json) | Minimum permissions of that role: mint the registry token, resolve one endpoint, publish and describe the packages of one scope |

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
