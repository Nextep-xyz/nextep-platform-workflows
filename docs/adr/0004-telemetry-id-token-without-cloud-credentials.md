# ADR 0004 — The telemetry job holds `id-token: write` with no cloud credentials

**Status: ACCEPTED as a design, verified by local tests only.** Not verified on a real runner against a real collector (spec phase F6): the
real value of the token's `job_workflow_ref`, the collector's answers and the re-run behaviour are open until then. Do not cite them as facts.

## Context

`SPEC.md` §6.5 / guard G2 allowed `id-token: write` only in jobs that assume a cloud role. The collector authenticates with a GitHub OIDC token
(its own audience) and checks the token's `job_workflow_ref` and claims against the body, so the telemetry job needs the permission too.

## Decision

1. `telemetry-phone-home` may hold `id-token: write` **only** with `permissions == {contents: read, id-token: write}`; it has exactly one step (the
   internal composite), no checkout, no `run:`, no cloud-credential action and no environment (guards G17, T8, G2).
2. The audience is **not free**: a plain slug `^[a-z0-9][a-z0-9-]{2,62}$`, validated in `validate-inputs.sh` and again inside the composite (the job runs with
   `always()` even when the gate failed). No dot, colon or slash, which excludes the default audience of AWS, Azure and GCP (guard T2).
3. The token is masked before its first use, travels in the request config on stdin and is never printed; only `job_workflow_ref` and `job_workflow_sha` are shown (guard T6).
4. Durations come from start/end stamps that each job exposes as outputs, not from the Actions API: that API needs `actions: read`, and a caller that does not grant it makes the
   whole workflow fail to start (the permissions of a reusable workflow cannot exceed the caller's).
5. No `upload-artifact`: a third-party action inside a job with `id-token: write` widens the attack surface. A resend is *Re-run job*, because the collector ties an event to the run that minted the token.

## Why the audience matters

A token minted inside a job of this repository's reusable workflow carries `job_workflow_ref = lego-*.yml@<tag>`. If a caller could choose the audience and the destination, it could send
itself a token with a cloud provider's audience and the workflow identity that a cloud trust policy conditioned on `job_workflow_ref` accepts (`SPEC.md` D2/G1): the barrier D2 builds would be
bypassed from the telemetry job. Constraining the audience closes it without relying on the destination.

## Residual risk

- An audience without dots that some cloud account happens to trust (unusual): an operator who configures a trust policy on a custom bare audience must not reuse the collector's.
- A caller can still choose where the (collector-audience) token is sent; it is only useful to the collector.
- Re-running the job after the original event arrived counts the deployment twice (the collector keys events by run and attempt). Runbook §4 says when to re-run.

## Fallback

If the collector or GitHub changes how the token is issued: keep the guards, change the composite. If the audience restriction proves too strict for a legitimate collector, widen the pattern in
`scripts/lib/telemetry.sh` **and** the gate T2 together, never one without the other.
