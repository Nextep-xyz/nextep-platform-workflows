# Runbook: adoption and operation of `lego-aws-cicd` and `lego-aws-environment-deploy`

> Status: **written, not exercised against a real account.** Everything marked NOT VERIFIED is an open question.

## 1. Adoption checklist (what a project must have before calling the workflows)

| Requirement | Detail |
|---|---|
| Repository variables | `AWS_ROLE_ARN_DEV`, `AWS_ROLE_ARN_STG`, `AWS_ROLE_ARN_PROD`. Variable names are case-insensitive. Never a literal ARN in a workflow |
| Caller permissions | `permissions: { id-token: write, contents: read, pull-requests: write }` on the caller job. Without `id-token` the OIDC step fails |
| Callers | See `test/sandbox/callers/`. The job id of the caller is part of the required check name: `<job-id> / quality-and-security-gate` |
| When it runs | The **caller** decides (`on.push.paths-ignore` etc.). A reusable workflow cannot filter by path or branch. `environment-deploy` must be `workflow_dispatch` only; the gate refuses any other event |
| Do not put `paths-ignore` on a pull-request workflow that is a required check | A skipped required check stays *pending* and blocks the merge of docs-only PRs |
| Branch protection | Rulesets on the deploy branches (PR + review), `CODEOWNERS` on `.github/workflows/`. There are **no GitHub Environments**, so there is no manual approval per environment: the barriers are `branch-map`, the manual-only trigger, the branch ruleset and the trust policy |
| Trust policy | One role per (project, environment). `prod` assumable only from `refs/heads/main`. Conditioning on `job_workflow_ref` is **NOT VERIFIED** (ADR 0001); see `docs/iam/` |
| Database access | A bastion reachable through SSM, the SSM parameters for its id and the DB endpoint, a secret with `username` and `password`. Policy: `docs/iam/deploy-role-ssm-tunnel-policy.example.json` |
| Project commands | Lint, test, migrate, migrate-status (and seed) as commands the caller passes as inputs; they receive `PROJECT`, `APP_ENV`, `APP_STAGE`, `STACK_SUFFIX`, `AWS_REGION` and, in database steps only, `DATABASE_URL` |

## 2. Deviations from the reference pipelines that are actually applied

| Reference behaviour | Here | Why |
|---|---|---|
| A rollback also ran the infra deploy and migrated | A rollback runs the infra deploy with the tag pinned and **never migrates** | The rollback does not migrate the database |
| Fast-flow concurrency cancelled in-progress runs, deploy included | `cancel-in-progress: false` on migration/deploy | Cutting a deploy in half leaves stacks half-done |
| The tunnel was opened 2-3 times per run | One tunnel session per job | Same guarantee, fewer minutes |
| Seed after the deploy | Seed right after the migration (idempotent by contract) | Avoids a second tunnel |
| The fast ECS flow migrated from the deploy job | Migration is its own job before the deploy | Separates responsibilities and permissions |
| `latest` pushed to every environment | `latest` only in `dev`; stg/prod get the immutable commit tag | Immutable tags for the pinned deploy |
| TLS verification disabled in the tunnel; `sleep` waiting for it; unpinned plugin; credentials in the runner env file | `verify-full` with a pinned CA bundle, port polling with timeout, pinned plugin with sha256, credentials only in the env of the step that uses them | Hard rules of this repository |

## 3. When something fails

| Symptom | Meaning | Action |
|---|---|---|
| `bastion ... is not Online ... switched off or outside its window` | The dev/stg bastion is stopped off-hours | Start it or retry inside its window. The job never waits |
| `the tunnel process ... died` + tunnel log | The SSM session could not be established | Read the printed log; check the role permissions and the bastion |
| `stage 'migration' failed` | The migration command exited non-zero | The deploy does not run. Fix forward; migrations are never reverted automatically |
| `database is NOT aligned after migrating` | The verify command still fails after the migration | The job is red on purpose. Do not deploy; investigate the pending state |
| `image '...' does not exist in ECR` | The rollback tag is wrong | Nothing was changed. Pick an existing tag |
| `N required runtime item(s) are missing` | Missing SSM parameters or secrets | The message lists all of them |
| Gate refuses the event or the branch | `environment-deploy` ran from a branch outside `branch-map` or from a non-manual trigger | Run it manually from an authorised branch |

Rollback (compute `ecs`): run `environment-deploy` with `image-tag` set to a previous tag. Nothing is built, the image must exist,
the database is not migrated.

## 4. Pending before the first release

Spikes S1, S3 and S4 and the dev integration runs (see `docs/adr/README.md` and `test/sandbox/README.md`), the rulesets of `main` and of
the `v*` tags, the `INTERNAL_DENYLIST` organization secret, and the real maintainers team in `CODEOWNERS`. No `v1` tag exists: only the release workflow creates tags.
