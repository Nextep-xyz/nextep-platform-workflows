# Runbook: adoption and operation of `lego-aws-cicd`, `lego-aws-environment-deploy` and `lego-aws-package-publish` (section 6)

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
| `this workflow publishes from a version tag only (got ref type 'branch' ...)` | `lego-aws-package-publish` was triggered by something other than the push of a tag | Fix the caller: `on.push.tags` only (section 6) |
| `tag '<tag>' does not match the package.json version '<v>': the tag for this version is '<prefix><v>'` | The tag and the manifest disagree (GR12). Nothing was installed or published | Fix the version, delete nothing: push a new tag that matches. A wrong tag that already exists stays wrong (never move or delete a tag by hand) |
| `package.json version '<v>' must be X.Y.Z or X.Y.Z-dev.N` | A suffix other than `-dev.N` (`-rc.1`, `-beta`, `-dev` with no number, `+build`) | Use `X.Y.Z` or `X.Y.Z-dev.N` (section 6.3) |
| `package name '<name>' must be '<scope>/<name>'` or `<file> sets publishConfig.registry` | The package is outside `package-scope`, or tries to choose its own registry | Rename it, or remove `publishConfig.registry` |
| `tarball file '<file>' line <n> holds a CodeArtifact URL` (or `a 12-digit number that may be a cloud account id`) | What `npm pack` would ship contains a registry URL or something that looks like an account id. The value is never printed | Remove it from the shipped file, or from `files` in `package.json` |
| `npm pack lists no files ...` | The package would be empty: the build did not produce what `files` or `main` point to (section 6.5) | Make `build-command` produce the files |
| `could not get a CodeArtifact authorization token` | The role cannot mint the token, or the trust policy did not match the run | Check the permissions of the role and its trust policy (`job_workflow_ref`, `sub`; section 6.2) |
| `<package>@<version> already exists in repository '<repo>'` | That version is published and a published version is immutable. Also what a re-run of a run that did publish shows | Nothing to fix if it was a re-run. Otherwise bump the version and push a new tag |
| `describe-package-version failed ... nothing was published` | An error other than "not found" while checking the version (permissions or an outage). It fails closed | Fix the permission or retry later; nothing was published |
| `npm publish failed for <package>@<version>` | The registry refused the publish | Read the npm error above it. The version may be half-published: check it in the registry before re-running |
| A `publish` run shown as **cancelled** | A newer run of the same package was queued behind a running one (concurrency, section 6.4) | Re-run it once the other one finishes |

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

Package publishing (section 6): the first run of `lego-aws-package-publish` against a real CodeArtifact repository, the exact set of CodeArtifact
actions of the publishing role, and `job_workflow_ref` in the role's trust policy are NOT VERIFIED (list at the end of section 6). The workflow is
in `main` and is released with `release.yml`; until a tag carries it, no caller can pin it.

## 6. Publishing packages (`lego-aws-package-publish`, since v1.4.0)

An npm package is published to AWS CodeArtifact when a **version tag** is pushed. The role is assumed through OIDC, the registry token is minted per run
(15 minutes, masked, never stored) and there is no secret and no token input anywhere (gate GR15).

### 6.1 What it does

Two jobs. Their names are in the trust policy of every publishing role and never change (`SPEC.md` section 12).

| Job | Holds cloud credentials | Does |
|---|---|---|
| `quality-and-security-gate` | no | Validates the inputs and that the trigger is a tag; checks `package.json` against the tag (scope, version, `tag == tag-prefix + version`, no `publishConfig.registry`, not `private`); installs; runs `test-command` then `build-command`; scans what `npm pack` would ship |
| `publish` (needs the gate) | only after the role is assumed | Repeats the validation and the manifest check (it is the job with `id-token`, it does not trust the previous runner); installs and **builds again** (the build output does not travel between jobs); scans the tarball; **then** assumes the role, mints the token, checks that the version does not exist yet, runs `npm publish --ignore-scripts`, and verifies the registry reports the version as `Published` |

The caller's `test-command` and `build-command` run before any role is assumed: caller code never sees cloud credentials. The token reaches exactly one step, the one that runs
`npm publish`, and only in its environment; the `.npmrc` it uses is a temporary file that holds a reference to the variable, never the value (gate GR15).

Inputs (contract: `contracts/lego-aws-package-publish.contract.yml`): `project`, `package-scope`, `tag-prefix`, `role-arn`, `codeartifact-domain`, `codeartifact-domain-owner` and
`codeartifact-repository` are required; `package-dir` (`.`), `aws-region` (`us-east-2`), `package-manager` (`pnpm`), `node-version` (`22`), `install-dirs` (`.`), `build-command` (empty) and `test-command` (`make test-ci`, never empty) are optional.

### 6.2 The caller and the barrier

The caller is [`test/sandbox/callers/package-publish.yml`](../test/sandbox/callers/package-publish.yml): a few lines that fire **only** on `push.tags` (a branch, a pull request or a manual run is not a release; gate GR-F4),
grant exactly `{ id-token: write, contents: read }`, take the role and the CodeArtifact coordinates from repository `vars` (this repository is public; so is the caller's YAML if the project is), and call the workflow **by tag**
(`@v1` or `@vX.Y.Z`), **never `@main`**: the trust policy of the role names the workflow at a tag.

The workflow cannot decide who is allowed to publish. The barrier is two things together, and neither is enough alone:

1. **A tag ruleset in the consuming repository**: only maintainers can create tags with the `tag-prefix`, and nobody can move or delete them. Whoever can push `<tag-prefix>*` can start a publication.
2. **The trust policy of the role** ([`docs/iam/package-publish-trust-policy.example.json`](iam/package-publish-trust-policy.example.json)): `aud` is `sts.amazonaws.com`, `job_workflow_ref` is this workflow's file at a release tag (list `@refs/tags/v1` if callers pin the alias, or each exact `@refs/tags/vX.Y.Z` they pin),
   and `sub` is the repository at the version tags (`repo:<org>/<repo>:ref:refs/tags/<tag-prefix>*`), never a branch and never a bare `repo:<org>/<repo>:*`. The permissions of the role are in [`package-publish-policy.example.json`](iam/package-publish-policy.example.json): no delete, copy or dispose.

One role per (project, package scope), separate from the deploy roles.

### 6.3 Versions and the pre-release flow

The only versions accepted are `X.Y.Z` and `X.Y.Z-dev.N` (`N` a number with no leading zeros). Any other suffix (`-rc.1`, `-beta.2`, `-dev`, `+build`) is refused with a message that names the version. The tag is always `<tag-prefix><version>`, suffix included
(`shop-lib-v1.4.0-dev.2`), and that equality (GR12) is checked before anything is installed.

- A stable version is published with the default dist-tag. A `-dev.N` is published with `--tag dev` (npm demands a tag for a pre-release, and `latest` must never point at one), so `npm install @scope/pkg` never picks it up; whoever wants it asks for `@scope/pkg@dev`.
- The flow: **pre-release → dev repository → stable.** Push `shop-lib-v1.4.0-dev.1` and publish to a **dev CodeArtifact repository** (the caller passes that repository from its own variable); the consumers try `@dev`; when it is good, bump to `1.4.0`, push `shop-lib-v1.4.0` and publish to the stable repository. A published version is immutable: a fix is a new version.
- Two callers do this cleanly: one for the dev tags with the dev role and repository, one for the stable tags with the stable ones. A tag filter can exclude the dev tags from the stable caller (`'!shop-lib-v*-dev.*'`). **Mind the glob:** `shop-lib-v*` also matches `shop-lib-v1.4.0-dev.1`, in the tag filter and in the trust policy's `sub`.
  Keep the stable role's `sub` from matching dev tags (for example with a `StringNotLike` on `*-dev.*`) if you do not want a dev tag able to assume it. Neither is verified (list below).

### 6.4 Re-running a run that shows "cancelled"

`publish` has a concurrency group per package (`package-publish-<project>-<package-dir>`) with `cancel-in-progress: false`: one publication at a time, and a running one is never interrupted. If a second tag of the same package is pushed while the first one runs, GitHub keeps one pending run per group,
so a third replaces the second, and the replaced run is shown as **cancelled** (it never ran). To publish it: open the run and *Re-run all jobs* when the running one has finished. Re-running a run that already published is harmless: it stops at the precheck with `already exists` and publishes nothing.

### 6.5 `--ignore-scripts` and what the build must produce

`npm pack` (the scan) and `npm publish` run with `--ignore-scripts`: **`prepack`, `prepare`, `prepublish`, `prepublishOnly` and `postpack` do not run**, because they would run with the registry token in their environment. So a package that builds in `prepack` ships nothing, and the scan fails with `npm pack lists no files`.
The caller's **`build-command` must produce every file that is published** (`dist/`, the compiled output), and `files` in `package.json` must list them.
### 6.6 Lint

There is no lint step and no lint input, on purpose: the gate runs `test-command`, and lint goes **inside it** (for example `pnpm run lint && pnpm run test`). `test-command` cannot be empty; a package with no tests passes `true` explicitly, in plain sight of the review.

### 6.7 NOT VERIFIED

Written from the documentation and verified only with `aws` and `npm` fakes. Nothing below has run against a real account or registry:

- **The exact set of CodeArtifact actions** the role needs: `GetAuthorizationToken` on the domain, `sts:GetServiceBearerToken` (with the `sts:AWSServiceName` condition), `GetRepositoryEndpoint` on the repository, and `PublishPackageVersion`, `PutPackageMetadata`, `DescribePackageVersion` on the packages of the scope. It may be one short or one too many; the first run in `dev` settles it.
- **`job_workflow_ref` as an IAM condition** of the trust policy (ADR 0001, [`docs/adr/0001-s1-job-workflow-ref-in-iam.md`](adr/0001-s1-job-workflow-ref-in-iam.md)). The `sub` condition is the documented one; if the claim cannot be conditioned, the tag ruleset and the `sub` are the whole barrier.
- **The integration against a real registry**: that `npm publish` honours `--userconfig` with the token reference and the forced `--@scope:registry=` over a project `.npmrc`, that `--tag dev` is accepted, that `describe-package-version` reports `Published` right after the publish, and that the endpoint check matches a real CodeArtifact endpoint.
- The tag filter with `!` and the `StringNotLike` on `sub` of section 6.3, and that a workflow called by an alias tag (`@v1`) reports that tag in `job_workflow_ref`.

