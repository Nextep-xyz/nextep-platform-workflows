# IAM examples (reference, placeholders only)

| File | What it is |
|---|---|
| [`deploy-role-ssm-tunnel-policy.example.json`](deploy-role-ssm-tunnel-policy.example.json) | Minimum permissions the deploy role needs for the SSM-tunnel migration (`SPEC.md §7.1`) |
| [`trust-policy.example.json`](trust-policy.example.json) | Trust policy of the role per (project, environment) |

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
