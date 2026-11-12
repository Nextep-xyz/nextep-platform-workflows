# Architecture decision records

Each spike of `SPEC.md §3.3` is closed with an ADR: decision, evidence and fallback applied.
**A spike with status `NOT VERIFIED` is an open question, not a fact**: do not cite it as one.

| ADR | Spike | Status |
|---|---|---|
| [0001](0001-s1-job-workflow-ref-in-iam.md) | S1 — `job_workflow_ref` as an IAM condition key | NOT VERIFIED (needs a dev AWS account) |
| [0002](0002-s3-cross-org-call-and-negative-test.md) | S3 — cross-organization call and negative test | NOT VERIFIED (needs a dev AWS account and a second org) |
| [0003](0003-s4-verify-full-over-ssm-tunnel.md) | S4 — `verify-full` over the SSM tunnel | NOT VERIFIED (needs a dev AWS account); `verify-full` stays the default |
| [0004](0004-telemetry-id-token-without-cloud-credentials.md) | Telemetry job with `id-token: write` and no cloud credentials | ACCEPTED (design, local tests); NOT VERIFIED on a real runner and collector (spec phase F6) |

## Repository settings still pending (cannot be applied offline)

- Ruleset of `main`: require the `self-ci` checks (`static-analysis`, `tests`, `secret-scan`) and Code Owners review.
- Ruleset of tags `v*`: only `release.yml` creates or moves them; no deletion, no force push.
- Organization secret `INTERNAL_DENYLIST` (G13). Without it `tests` fails on purpose in CI.
- Real maintainers team in `.github/CODEOWNERS` (the file ships a placeholder).
