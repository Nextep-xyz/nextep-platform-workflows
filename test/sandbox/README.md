# Sandbox callers

Fictional callers (project `shop`) that show how a repository calls the reusable workflows. They live outside
`.github/` on purpose: they are **not** run by this repository. To exercise them, copy one into the `.github/workflows/`
of a scratch repository in a **dev** account, set the repository variable `AWS_ROLE_ARN_DEV`, and call by branch
(`@main`) until the tag `v1` exists.

| Caller | Covers |
|---|---|
| [`cicd-ecs.yml`](callers/cicd-ecs.yml) | `lego-aws-cicd`, `compute: ecs` |
| [`cicd-lambda.yml`](callers/cicd-lambda.yml) | `lego-aws-cicd`, `compute: lambda` |
| [`environment-deploy.yml`](callers/environment-deploy.yml) | `lego-aws-environment-deploy`, `compute: lambda` |
| [`cicd-lambda-hub-like.yml`](callers/cicd-lambda-hub-like.yml) | `lego-aws-cicd`, lambdalith, `db-access: iam-direct`, two package roots, hotswap in dev/stg |
| [`environment-deploy-hub-like.yml`](callers/environment-deploy-hub-like.yml) | `lego-aws-environment-deploy`, `migrate-before-deploy`, `post-deploy-command`, several branches to one environment |
| [`environment-deploy-static.yml`](callers/environment-deploy-static.yml) | `lego-aws-environment-deploy`, `compute: static` (single-page app: build as prepare, guard, deploy, verification; no database stage) |
| [`cicd-static.yml`](callers/cicd-static.yml) | `lego-aws-cicd`, `compute: static` |
| [`cicd-telemetry.yml`](callers/cicd-telemetry.yml) | `lego-aws-cicd` reporting to a DORA collector: `telemetry-url`/`telemetry-audience` from variables, pinned by tag (`@v1`) |

**Status: NOT VERIFIED.** Nothing here has been run against a real account. The dev integration runs of the spec
(`SPEC.md` P1.3/P1.4) are pending until a dev AWS account is available.

Things to check on the first real run (open questions, not facts):

- `vars[format(...)]` resolving inside `with:` of a caller (used by the environment-deploy example).
- `pnpm/action-setup` with an empty `version` falls back to the `packageManager` field.
- The Session Manager plugin installs on `ubuntu-latest` with `dpkg -i` and `sudo`.
- `verify-full` over the tunnel with the project's ORM (spike S4).
