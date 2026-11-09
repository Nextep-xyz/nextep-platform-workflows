# ADR 0003 — S4: `verify-full` over the SSM tunnel

**Status: NOT VERIFIED.** Skeleton only; no evidence has been collected.

## Question

Does adding `127.0.0.1 <db-endpoint>` to `/etc/hosts` and trusting a pinned CA bundle give full certificate
verification (`sslmode=verify-full`) through the SSM port-forwarding tunnel, with the ORM of the consuming project?

## Evidence

None yet. Needs a bastion and a database in a dev account.

## Decision

Until verified, the default of `db-ssl-mode` stays `verify-full` (the secure one). If the spike fails, the fallback below
is adopted **with a new ADR** before any release; `NODE_TLS_REJECT_UNAUTHORIZED=0` and `sslmode=disable|no-verify` are never an option (G9).

## Fallback if it fails

`sslmode=require` (encrypts, does not verify).
