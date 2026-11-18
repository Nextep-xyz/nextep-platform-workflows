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
| `could not get a CodeArtifact authorization token` (publishing, and the registry login of section 7) | The role cannot mint the token, or the trust policy did not match the run | Check the permissions of the role and its trust policy (`job_workflow_ref`, `sub`; section 6.2) |
| `<package>@<version> already exists in repository '<repo>'` | That version is published and a published version is immutable. Also what a re-run of a run that did publish shows | Nothing to fix if it was a re-run. Otherwise bump the version and push a new tag |
| `describe-package-version failed ... nothing was published` | An error other than "not found" while checking the version (permissions or an outage). It fails closed | Fix the permission or retry later; nothing was published |
| `npm publish failed for <package>@<version>` | The registry refused the publish | Read the npm error above it. The version may be half-published: check it in the registry before re-running |
| A `publish` run shown as **cancelled** | A newer run of the same package was queued behind a running one (concurrency, section 6.4) | Re-run it once the other one finishes |
| `the job has no id-token: write permission, so the registry role cannot be assumed` | `registry-role-arn` is set but the job has no OIDC token: the caller did not grant `id-token: write`, or it is a pull request from a fork (forks never get it) | Grant `id-token: write` in the caller. For a fork there is no fix: a maintainer re-runs it from a branch of the repository |
| `input '<name>' is required when any registry input is set` (or `... is not an IAM role ARN`, `... is not a 12-digit account id`) | The five registry inputs go together, or none: a half-configured registry is never a silent skip | Set all five from repository variables, or none (section 7.2) |
| `could not assume the registry role (does its trust policy allow this repository and this workflow? ...)` | STS refused the OIDC token: the trust policy of the registry role does not match the repository (`sub`) or the workflow the job runs in (`job_workflow_ref`, called by tag) | Check the trust policy against `docs/iam/registry-read-trust-policy.example.json`; the caller must call the workflow by tag |
| `E401` / `ERR_PNPM_FETCH_401` while installing a private package | The registry rejected the token: the role lacks `ReadFromRepository` on that repository, the scope is served by another repository, or a project `.npmrc` sets its own `@scope:registry` (it wins over the temporary user config, section 7.4) | Fix the role or the inputs; remove the scope registry from the project `.npmrc` |

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

Registry login in the gates and the deploys (section 7): a real registry with a published private package, the exact set of read actions of the role, `job_workflow_ref` in its trust
policy and the first run in `dev` are NOT VERIFIED (list at the end of section 7). It is prepared for v1.5.0 and not released.

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

## 7. Private packages in the gates and the deploys (`registry-role-arn`, prepared for v1.5.0)

`lego-aws-cicd` and `lego-aws-environment-deploy` can install private `@scope/*` packages from CodeArtifact through OIDC, with no static token. It is **opt-in**: with `registry-role-arn` empty
no role is assumed and every job behaves exactly as before.

### 7.1 What it does

Every job that installs dependencies (`setup-project`: the gate and the deploy jobs) runs, just before the immutable install, one extra step, `Get the registry token`, when `registry-role-arn` is set. The step:

1. asks the runner for the OIDC token of the job (audience `sts.amazonaws.com`) and masks it;
2. assumes the **read-only** registry role with it (`sts assume-role-with-web-identity`, 15 minutes) **inside the script**: the role credentials exist only in that process and in the two CodeArtifact calls, never in the runner env file nor in a later step
   (this is also why it does not use `aws-actions/configure-aws-credentials`, which exports them to every later step, and does not clash with the environment role that the deploy jobs assume afterwards);
3. asks CodeArtifact for an authorization token (15 minutes) and the npm endpoint, and masks the token **before** it is written to the step output.

The token reaches **one** step, the install, in its `env:` (`CODEARTIFACT_AUTH_TOKEN`). `install-dirs.sh` writes a **temporary** npm user config with `@scope:registry=<endpoint>` and
`//host/path/:_authToken=${CODEARTIFACT_AUTH_TOKEN}` (a reference: npm and pnpm expand it themselves), hands it over with `NPM_CONFIG_USERCONFIG` in that process only, and deletes it when the install ends, also if it fails.

### 7.2 Configuring a caller

Five repository variables, never literals (this repository is public, and so is the caller's YAML if the project is), passed together: `registry-role-arn`, `codeartifact-domain`, `codeartifact-domain-owner`,
`codeartifact-repository` and `registry-scope` (for example `@example`). The region is the existing `aws-region` input. Example: [`test/sandbox/callers/cicd-registry-login.yml`](../test/sandbox/callers/cicd-registry-login.yml).

The permissions the caller already grants (`id-token: write`, `contents: read`, `pull-requests: write`) are enough; the gate job now holds `id-token: write` too (amendment of G2, `SPEC.md` section 0), only to log in.
`validate-inputs` refuses a partial set naming what is missing. The role and its policies: [`docs/iam/`](iam/README.md) (`registry-read-*.example.json`).

### 7.3 What stays true

- No secret, no token input, no `.npmrc` in the project, no `~/.npmrc`, no `aws codeartifact login`, nothing in the runner env file; the token is masked before it is written and lives in one step's `env:` (gates GR15 and GL1-GL3).
- Every `setup-project` call of the two workflows passes the registry inputs (gate GL4), so a job that installs without the login cannot appear by omission.
- `lego-aws-package-publish` does not use this login and does not change.

### 7.4 Limits you should know

- **The role is the whole defence, and it is read-only.** The gate runs the code of the pull request with `id-token: write`; that permission belongs to the job, so that code can ask for the same OIDC token and assume the same role. It can read one repository and nothing else.
  A pull request from a fork gets no `id-token`, so the login fails there with a message saying so; install nothing private for forks.
- **A project `.npmrc` that sets `@scope:registry` wins** over the temporary user config (project config has precedence over user config in npm and pnpm). Do not set it in the project: the workflow points the scope at the registry.
- The token lasts 15 minutes; an install that takes longer needs a role with a longer session (not configurable here).
- Each job logs in on its own (a run with a gate, a migration and a deploy mints three tokens).

### 7.5 Reading a failure

See the rows of section 3 (`no id-token`, `is required when any registry input is set`, `could not assume the registry role`, `could not get a CodeArtifact authorization token`, `E401`). Every message names the input or the permission to check and never prints the role, the account or a token.

### 7.6 Verified and NOT VERIFIED

**Verified** (locally, with `aws`, `curl`, `npm` and `pnpm` fakes in the suite, and a fake registry for the package managers):
the order of the calls, the masking, that nothing reaches the runner env file or the step outputs but the token and the endpoint, the shape and the removal of the temporary user config, the all-or-none rule, and gates GL1-GL4 and G2 in red.
Against a **local fake registry** that demands a bearer token on every request ([`test/sandbox/pm-userconfig/run.sh`](../test/sandbox/pm-userconfig/run.sh), manual, needs the network to fetch pnpm): `pnpm install --frozen-lockfile` with pnpm 9.15.9 and 10.34.9, and `npm ci` with npm 9.2.0, install the
private package using that temporary user config and the token in the environment, send the bearer token, and without the config the package is not reachable (pnpm asks the public registry and gets a 404); with the config but no token in the environment pnpm warns `Failed to replace env in config` and the install fails.
This is a check of the package managers, **not** of CodeArtifact.

**NOT VERIFIED** until a registry with a published package exists (`test/sandbox/callers/cicd-registry-login.yml` is the caller to run in `dev`):
- the real integration: `sts assume-role-with-web-identity` with the OIDC token of a job, `get-authorization-token` and `get-repository-endpoint` against a real domain, and the install of a published package through the real endpoint;
- that the AWS CLI on `ubuntu-latest` calls `assume-role-with-web-identity` unsigned, as it does on a developer machine, and the 900-second session;
- the exact set of read actions of the role (`GetAuthorizationToken`, `sts:GetServiceBearerToken`, `GetRepositoryEndpoint`, `ReadFromRepository`) and `job_workflow_ref` as an IAM condition (ADR 0001);
- a lockfile that stores the CodeArtifact tarball URL (it matches the standard pattern of the endpoint, so the install should resolve it through the scope registry).

## 8. Releasing this repository (`release.yml`)

A release is **one manual workflow**, not a recipe of commands. `release.yml` is the only thing that creates the tags `vX.Y.Z` and moves the alias `vX` (the tag ruleset is configured in GitHub, not in this repository).
It works out **whether** there is something to release and **which version** it gets, checks that the CI is green, runs the suite, publishes the release and verifies the result on the remote. Anyone with permission to run workflows can do it by reading this section.

### 8.1 How to release

1. Merge what you want to release into `main` and let `self-ci` finish. The workflow refuses to run from any other branch.
2. **Always start with a dry run.** *Actions* → *release* → *Run workflow* → branch `main`, `dry_run` ticked. Or, from PowerShell:

   ```powershell
   gh workflow run release.yml --ref main -f dry_run=true
   # wait a few seconds so the new run shows up, then take it:
   $id = (gh run list --workflow release.yml --limit 1 --json databaseId | ConvertFrom-Json)[0].databaseId
   gh run watch $id --exit-status
   gh run view $id --log | Select-String 'next=|level=|release='
   ```

3. Read the plan (section 8.4). If it is what you expect, run it for real, with the same inputs and `dry_run` off:

   ```powershell
   gh workflow run release.yml --ref main
   ```

   To skip versions or to cut a major, pass the version explicitly (section 8.3): `gh workflow run release.yml --ref main -f version=1.5.0`.
4. The job ends green only after the final verification passed. Nothing else to do: no `git tag`, no `git push`, no manual checks.

### 8.2 Inputs

| Input | Values | Effect |
|---|---|---|
| `bump` | `auto` (default), `patch`, `minor` | `auto` computes the level from the changes. `patch` / `minor` force the level but **never below what the contracts require** (a forced `patch` over an additive contract change is refused). There is no `major` here |
| `version` | empty (default) or `X.Y.Z` | An explicit version. **The only way to a major**, and the way to skip versions. Needs `bump=auto`. It must be greater than the last release and must not exist |
| `dry_run` | `false` (default) / `true` | Computes the plan and checks the CI, then stops: it does not run the suite, build the tree, commit, tag or push. Nothing changes |

### 8.3 What it decides

- **Is there anything to release?** Everything versioned counts **except** the paths listed in [`docs/release-surface.yml`](release-surface.yml) (docs, tests, root markdown, the CI of this repository, the release machinery itself). A new file outside that list triggers a release by default: a release too many is cheap, a change that never ships is not.
  If nothing on the surface changed since the last release, the run ends **green with no tag** and says so in the summary. That is also what a second dispatch queued behind a release does.
- **Which level?** The highest of three, computed against the last release:

  | Source | patch | minor | major |
  |---|---|---|---|
  | **Contracts** (`contracts/*.contract.yml`, a floor that does not depend on how a commit was written) | none of the below | a new optional input, secret, output or job; a new contract; a changed `default` | a removed or renamed input, secret, output or job; a changed `type`; an input that becomes `required`; a new `required` input without a default or a new required secret; a deleted contract or workflow |
  | **Commits that touch the surface** (`type(scope)!: subject`) | `fix`, `ref`, `infra`, `chore`, `docs` (and an unrecognised prefix, with a warning) | `feat` | a `!` after the type, or a `BREAKING CHANGE:` footer |
  | `bump` | `patch` | `minor` | never |

- **A major is never automatic.** If the changes are incompatible, `auto` fails and lists each one. To proceed, update the trust policies of **every** account first (they list `@refs/tags/v1`; a `v2` is a new reference) and then pass `version=2.0.0`. Skipping the trust policies means the first deploy that pins `v2` is denied.
- **The base of the comparison** is the parent of the last release commit, not the tag itself: the release commit is built on top of the source commit and is not in the history of `main`.

### 8.4 Reading the summary

The summary of the run is the plan. It lists the last release, the surface files changed, **each contract change with its level**, each commit that touches the surface with its level, the warnings, the final level and the next version. The same values are in the log as `release=`, `last=`, `base=`, `next=`, `level=`.
Commit subjects shown there are neutralised (workflow commands and markup are escaped): they are data, never executed. After a real release the summary also has a table with the commit that `vX.Y.Z` and `vX` point to, the parent of the release commit and the released source.

### 8.5 When something fails

| Message | Cause | What to do |
|---|---|---|
| `releases are cut from main only` | Run started from another branch | Re-run from `main` |
| `an explicit version needs bump=auto` | `version` and `bump=patch/minor` together | Choose one |
| `there is no release tag yet: the first release needs an explicit --version` | No `vX.Y.Z` tag in the clone | Pass `version` (and check the checkout fetched the tags) |
| `... include an incompatible one and auto never produces a major` | A contract or a commit breaks compatibility | See the list in the message; if it is intended, update the trust policies and pass `version`; if not, fix the change |
| `--bump patch is below the mechanical floor minor` | The contracts add something and you forced a lower level | Use `auto` or the level the message says |
| `version X is not greater than the last release` / `vX already exists` | The explicit version is behind or taken | Pick a greater version. A published tag is never moved or deleted |
| `vX.Y.Z is anomalous: its commit must have exactly one parent` / `...is not the canonical 'release: ...'` | A tag that was **not** created by `release.yml` (a manual or lightweight tag) | Stop. The comparison base would be false. Find out who created it; do not delete it by hand without a decision of the maintainers |
| `the base ... is not an ancestor of HEAD` | `main` was rewritten after the last release | Stop and investigate; releases assume a linear history from the released source |
| `the CI of <sha> is not green` / `did not finish within 600s` | A job declared in `self-ci.yml` failed, or never finished | Fix `main` (or re-run the failed job) and dispatch again. The required jobs are read from `self-ci.yml`; do not list them anywhere else |
| `0 surface files discovered` / `0 contracts discovered` | The tree has no surface or no contracts: the decision would be over nothing | The checkout or the tree is broken. Do not release |
| `the release plan could not be computed` | Any of the above in `next-version.sh` (the reason is in the log and in the summary) | Read the line before it |
| `verify-release-tags: ... do not point to the same commit` / `not the released source` | **The tags are already published.** The check ran after the push | Do not retry and do not move anything. Compare what the summary lists and ask the maintainers |
| The `Mint the release token` step or the checkout fails with an authentication error | The release GitHub App is not installed on this repository, its key was rotated or deleted, or `RELEASE_APP_ID` is wrong | Section 8.7 lists each message and the rotation; there is no personal token to renew |

### 8.6 Rules that do not change

- **Never create, move or delete a tag by hand**, not even to test. Only `release.yml` does, and only `vX.Y.Z` (immutable) and `vX` (the alias, which moves forward on each release).
- **A published release is not undone.** A defect is fixed with the next patch. What can be reverted is the code, with a normal commit.
- The tags are `vX.Y.Z` and `vX` only: the telemetry collector rejects anything else (`vX.Y`, a pre-release, a sha). Pre-releases (`-dev.N`) of the *packages* (section 6) are a different thing and live in the consumers' repositories.
- Every step that runs the suite, builds the tree or changes git is gated by `dry_run`, and the job holds only `contents: write` and `checks: read`; the release token is used for the checkout and nowhere else (gates RA5 and RA10).

### 8.7 The push credential: the release GitHub App

`release.yml` pushes commits that touch `.github/workflows`, which `GITHUB_TOKEN` cannot do. The credential is a token of the **release GitHub App**
(`actions/create-github-app-token`): one hour, this repository only, `contents: write` + `workflows: write`, revoked when the job ends.
No person owns it: a suspended or departed account does not stop a release. A personal token (`RELEASE_TOKEN`) must **not** come back (gate RA10).

| Piece | Where | Note |
|---|---|---|
| The App (`Nextep-xyz` → Settings → Developer settings → GitHub Apps) | Organization | Installed **only** on this repository. Permissions: Contents RW, Workflows RW, Metadata R. Webhook off. Keep at least two organization owners |
| `RELEASE_APP_ID` | Repository **variable** | Not a secret |
| `RELEASE_APP_PRIVATE_KEY` | Repository **secret** | The only long-lived secret of the release. Rotate it: *App → Credentials → Key pairs → Generate*, then `Get-Content <key>.pem -Raw \| gh secret set RELEASE_APP_PRIVATE_KEY`, run a `dry_run`, delete the old key in the App and the `.pem` from disk. Rotation date: write it here when you do it |

Errors of the first step (`Mint the release token`): `Not Found` = the App is not installed on this repository; `A JSON web token could not be decoded` = the key is
malformed or from another App; `Resource not accessible by integration` = the App lacks `workflows: write`.

