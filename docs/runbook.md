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

### 1.1 A Python project (`python-version` + `python-requirements`, since v1.3.0)

| Rule | Detail |
|---|---|
| Both or none | `python-version` (`3.12` or `3.12.7`) and `python-requirements` (comma separated relative paths, installed in order) go together. One without the other fails the gate naming the input |
| Pins are mandatory | Every requirement is `name==version` (extras and environment markers are fine) or carries `--hash=`. Ranges (`>=`, `~=`, `<`, `!=`, `==1.*`), unversioned names, `-e`, URLs/VCS and the source options `--index-url`, `--extra-index-url`, `--find-links`, `--trusted-host` are rejected **naming file and line, before anything is installed**. This is the `--frozen-lockfile` of pip: two runs of one commit install the same thing, and an extra index is the classic dependency-confusion vector |
| Prefer one compiled file | A `pin ==` of the direct dependencies only is **not** a lockfile: the transitive tree can still move. Compile the whole tree with hashes (for example `pip-compile --generate-hashes`) and pass that file; pip then enforces the hashes by itself |
| Nested files | `-r` / `-c` are followed (relative to the file that names them, inside the repository, at most 3 levels, no cycles) and validated like the top-level files |
| Node stays | Node and the package-manager install still run (a project whose infrastructure is a CDK app needs them). Python is added, never swapped in |
| No `venv` | The runner is ephemeral: `python`, `pytest` or `alembic` are on the `PATH` of your commands |
| Database URL | `test-database-image` and the migration hand your commands a `postgresql://` URL. A driver dialect (`postgresql+asyncpg://`) is adapted by the command itself (for example `${TEST_DATABASE_URL/postgresql:\/\//postgresql+asyncpg:\/\/}`) |

Example: `test/sandbox/callers/cicd-python.yml`.

### 1.2 A service with no database (`migrate: false`, since v1.3.0)

`lego-aws-environment-deploy` runs the database stage by default, and for `compute: ecs` or `lambda` it then requires the bastion, endpoint, secret and name.
A service with no database says so explicitly with `migrate: false`:

- No tunnel, no `database-migration` job, no separate `post-deploy` job. `post-deploy-command` runs as the last step of `infra-deploy`, as it does for `compute: static`. A run is two runners.
- Every database input that carries a value is **rejected** (`bastion-id-ssm-param`, `db-endpoint-ssm-param`, `db-secret-id`, `db-name`, `db-schema`, `migration-pre-command`, `post-migrate-command`, `db-access: iam-direct`, `migrate-before-deploy: true`, and the two migration commands when they differ from their default). The caller carries no configuration that looks like it does something, and a service that *has* a database cannot switch the stage off without deleting that configuration in plain sight of the review.
- It is **not inferred** from empty `db-*` inputs: today that omission is a useful error ("input 'db-name' is required to migrate").
- Rollback by `image-tag` is unchanged. `compute: static` ignores `migrate` (it has no stage).
- Telemetry reports the migration stage as `skipped`, like `compute: static` and a rollback. Example: `test/sandbox/callers/environment-deploy-ecs-no-db.yml`.

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
| `Telemetry not sent: ... HTTP 403 (workflow_not_allowed)` | The caller does not pin the workflow by tag: the collector only accepts `lego-*.yml@refs/tags/v…` in the token's `job_workflow_ref` | Call `@v1` (or `@vX.Y.Z`), never `@main`, a sha or a branch. The deploy was not affected |
| `Telemetry not sent: ... (claim_mismatch \| repo_not_registered \| not_allowlisted \| unknown_environment)` | The collector does not know this repository, project or environment label | Register it in the collector's registry (a change in the collector's repository, not here) |
| `Telemetry not sent: ... (schema_invalid)` | The payload does not match the collector's schema version | Compare `contracts/telemetry.schema.json` with the collector's; both repositories change together |
| `python-install: <file>:<line>: range specifier is not allowed` (or `has no version`, `URL or VCS requirement`, `package source option`, `editable install`) | A requirements file has something that is not pinned or that changes where packages come from | Pin it with `==` (or compile the file with hashes); remove the source option and configure the index on the runner's side. All problems of all files are listed at once; nothing was installed |
| `input 'python-version' needs 'python-requirements'` (or the reverse) | Only one of the two Python inputs was set | Pass both |
| `input '<name>' is not allowed with migrate=false` | A database input was left in a caller that switched the database stage off | Delete the input, or drop `migrate: false` if the service does have a database |
| Gate refuses the event or the branch | `environment-deploy` ran from a branch outside `branch-map` or from a non-manual trigger | Run it manually from an authorised branch |

Rollback (compute `ecs`): run `environment-deploy` with `image-tag` set to a previous tag. Nothing is built, the image must exist,
the database is not migrated.

## 4. Telemetry (opt-in)

Design and guards: `docs/specs/telemetria-dora/SPEC.md`. To report a project:

1. Repository variables (never literals): `TELEMETRY_URL` (https base URL of the collector) and `TELEMETRY_AUDIENCE` (a plain slug, no dots; the collector's token audience).
2. In the caller: `telemetry-url: ${{ vars.TELEMETRY_URL }}`, `telemetry-audience: ${{ vars.TELEMETRY_AUDIENCE }}`, the workflow pinned by tag (`@v1`) and the permissions the caller already needs (`id-token: write`, `contents: read`). See `test/sandbox/callers/cicd-telemetry.yml`.
3. The collector must know the repository (its own registry). Until it does, the step shows `repo_not_registered` and nothing else is affected.

**Reading a run.** The job `telemetry-phone-home` writes a summary: HTTP status, the collector's error code if any, the `idempotency_key`, the token's `job_workflow_ref` / `job_workflow_sha` (the only claims printed) and the payload.
The token is never printed.

**Resending.** The collector ties an event to the run that minted the token (run id, attempt and key must match the claims), so a saved JSON cannot be posted later from elsewhere.
Resend with *Re-run job* `telemetry-phone-home` in the run: the job rebuilds the event with the new attempt and the stored stamps (`finished_at` does not move). Do it **only if the summary says the event was not accepted**:
if the first one did arrive, attempt 2 counts again. `telemetry-unsent.json` (in `$RUNNER_TEMP/telemetry`) and the summary are the record of what did not arrive.

**Never pin the caller to a sha or a branch if you want telemetry**; and never create `vX.Y` tags: the collector accepts `vX` and `vX.Y.Z` only.

## 5. Pending

Spikes S1, S3 and S4 and the dev integration runs (see `docs/adr/README.md` and `test/sandbox/README.md`), the rulesets of `main` and of
the `v*` tags, the `INTERNAL_DENYLIST` organization secret, and the real maintainers team in `CODEOWNERS`. The `vX.Y.Z` tags and the `v1` alias
already exist: only the release workflow creates or moves them, never by hand.
