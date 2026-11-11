# ADR 0001 — S1: `job_workflow_ref` as an IAM condition key

**Status: NOT VERIFIED.** Skeleton only; no evidence has been collected.

## Question

Does the IAM trust policy of a GitHub OIDC provider accept
`token.actions.githubusercontent.com:job_workflow_ref` as a condition key, so that a role can only be assumed by a
workflow of this repository (`SPEC.md` D2, guard G1)?

## Evidence

None yet. To collect in a dev account: create a role whose trust policy conditions on `job_workflow_ref`, call it
from a reusable workflow of this repository and from a workflow of the caller, and record both results.

## Decision

Pending.

## Fallback if it fails

Customize the `sub` claim of the repository with `include_claim_keys` including `job_workflow_ref`, and condition on `sub`.
