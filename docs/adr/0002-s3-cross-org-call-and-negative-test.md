# ADR 0002 — S3: cross-organization call and negative test

**Status: NOT VERIFIED.** Skeleton only; no evidence has been collected.

## Question

1. Can a repository of **another organization** call the public reusable workflows?
2. Does a consumer repository with **its own workflow** get `AccessDenied` when it assumes the role (negative test of G1)?

## Evidence

None yet. Needs a dev AWS account (and a second organization for question 1).

## Decision

Pending.

## Fallback if it fails

One mirror of this repository per consuming organization (`SPEC.md` D1-B).
