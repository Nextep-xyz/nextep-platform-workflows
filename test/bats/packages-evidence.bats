#!/usr/bin/env bats
# scripts/packages-evidence.sh: the evidence of the @nextep/* packages in the step summary. The lockfiles of test/fixtures/packages-evidence are the
# REAL output of pnpm and npm for a tarball dependency (host and organization replaced by example-org/shop). `nextep-guardrails` is a fake that
# lives in node_modules/.bin of the test directory: the script runs that path and nothing else. Fictional data.
#   (a) no packages -> n/a, never a tick      (b) packages + green validation -> ✅      (c) failed validation -> ❌ visible
#   (d) a range / a foreign URL / no lockfile -> ❌      (e) the block is written even when the step before it failed

load 'helpers'

URL='https://github.com/example-org/shop/releases/download/v0.1.0/nextep-cdk-guardrails-0.1.0.tgz'
FX="$REPO_ROOT/test/fixtures/packages-evidence"

setup() {
  unset INTERNAL_DENYLIST GATE_FORK_PR CODEARTIFACT_AUTH_TOKEN GITHUB_TOKEN INSTALL_DIRS PACKAGE_MANAGER VALIDATIONS
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$GITHUB_STEP_SUMMARY"
  export GITHUB_REPOSITORY=example-org/shop GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_REF=refs/heads/main
  export GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=2
  export JOB_WORKFLOW_REF='example-org/platform/.github/workflows/lego-node-ci.yml@refs/tags/v9.9.9'
  export FAKE_LOG="$BATS_TEST_TMPDIR/guardrails.log"
  : >"$FAKE_LOG"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  cd "$PROJ"
}

summary() { cat "$GITHUB_STEP_SUMMARY"; }

pass_all() { export VALIDATIONS=$'Tests=success\nTypecheck=success'; }

use_pnpm() { cp -r "$FX/pnpm/." "$PROJ/"; }
use_npm() {
  cp -r "$FX/npm/." "$PROJ/"
  export PACKAGE_MANAGER=npm
}

# fake_guardrails [<exit code>] [<stdout lines...>]: the installed binary. It records what the script gave it (arguments, and whether any secret
# variable of the CI was in its environment: it must see none).
fake_guardrails() {
  local rc=${1:-0}
  shift || true
  mkdir -p "$PROJ/node_modules/.bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "args=$* secrets=$(env | grep -cE "INTERNAL_DENYLIST|CODEARTIFACT|GITHUB_TOKEN|GITHUB_STEP_SUMMARY" || true)" >>"'"$FAKE_LOG"'"'
    local l
    for l in "$@"; do printf 'echo %q\n' "$l"; done
    echo "exit $rc"
  } >"$PROJ/node_modules/.bin/nextep-guardrails"
  chmod +x "$PROJ/node_modules/.bin/nextep-guardrails"
}
default_guardrails() {
  fake_guardrails 0 \
    'EX-COST-001  error  stages=dev,stg,prod  excepcion=no  Example rule one' \
    'EX-FIN-002   warn   stages=prod  excepcion=si  Example rule two' \
    'EX-POWER-003  error  stages=dev  excepcion=no  Example rule three'
}

# --- (a) no packages -------------------------------------------------------------------------------------------------------------------
@test "(a) a repository with no @nextep/* dependency: n/a, and no tick anywhere, even with green validations" {
  printf '{ "name": "app", "dependencies": { "left-pad": "1.3.0" } }\n' >package.json
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: n/a'
  summary | grep -q '\*\*n/a\*\*'
  absent '✅' "$GITHUB_STEP_SUMMARY"
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  summary | grep -q 'passed (no packages to evidence)'
}

@test "(a) a failed validation with no packages is still red; the table says so" {
  printf '{ "name": "app" }\n' >package.json
  VALIDATIONS=$'Tests=failure' run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -q '❌ FAILED'
  absent '✅' "$GITHUB_STEP_SUMMARY"
}

@test "(a) only in-repo (workspace:) packages is not evidence either: n/a, shown as such" {
  printf '{ "name": "app", "dependencies": { "@nextep/lib": "workspace:*" } }\n' >package.json
  : >pnpm-lock.yaml
  printf 'lockfileVersion: '"'9.0'"'\nimporters:\n  .:\n    dependencies: {}\n' >pnpm-lock.yaml
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: n/a'
  summary | grep -q 'in-repo package'
  absent '✅' "$GITHUB_STEP_SUMMARY"
}

# --- (b) packages with a green validation ----------------------------------------------------------------------------------------------
@test "(b) pnpm: a Release tarball with integrity, an exact URL and green validations -> VERIFIED, with the whole header" {
  use_pnpm
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF "| \`@nextep/cdk-guardrails\` | \`package.json\` (dependencies) | \`0.1.0\` | \`$URL\` |"
  summary | grep -qE '`sha512-VU8Lx\+/7T4u…[^`]{6}`'
  summary | grep -qF '| yes (Release URL) | ✅ |'
  # header: repo, short commit, ref, UTC, link to the run (with attempt), exact platform tag
  summary | grep -qF '| Repository | `example-org/shop` |'
  summary | grep -qF '| Commit | `0123456` |'
  summary | grep -qF '| Ref | `refs/heads/main` |'
  summary | grep -qE '\| Generated \(UTC\) \| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \|'
  summary | grep -qF '[4242 (attempt 2)](https://github.com/example-org/shop/actions/runs/4242/attempts/2)'
  summary | grep -qF '| Platform | `example-org/platform/.github/workflows/lego-node-ci.yml@refs/tags/v9.9.9` |'
  # the validations are the ones reported
  summary | grep -qF '| `Tests` | ✅ passed |'
  summary | grep -qF '| `Typecheck` | ✅ passed |'
}

@test "(b) the guardrails rules come from the installed binary, offline: how many and which ids" {
  use_pnpm
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -qF '| `@nextep/cdk-guardrails` | `.` | 3 | EX-COST-001, EX-FIN-002, EX-POWER-003 |'
  grep -q '^args=--list-rules ' "$FAKE_LOG"
  [ "$(wc -l <"$FAKE_LOG")" -eq 1 ]
}

@test "(b) npm: package-lock.json resolves the same package: VERIFIED" {
  use_npm
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF "\`$URL\`"
}

@test "(b) the block is appended: what the summary already had is kept" {
  use_pnpm
  default_guardrails
  pass_all
  echo 'previous content' >"$GITHUB_STEP_SUMMARY"
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$GITHUB_STEP_SUMMARY")" = 'previous content' ]
  summary | grep -q 'VERIFIED'
}

# --- (c) a failed or skipped validation ------------------------------------------------------------------------------------------------
@test "(c) a failed validation is red in the headline and in its row, and VERIFIED never appears" {
  use_pnpm
  default_guardrails
  VALIDATIONS=$'Tests=failure\nTypecheck=skipped' run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `Tests` | ❌ FAILED |'
  summary | grep -qF '| `Typecheck` | ⏭️ did not run (skipped) |'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::warning::packages evidence: at least one package or validation is not green"* ]]
}

@test "(c) cancelled and an unknown outcome are red too; an empty outcome (a step that was never wired) is not a pass" {
  use_pnpm
  default_guardrails
  VALIDATIONS=$'A=cancelled\nB=\nC=maybe' run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -qF '| `A` | ❌ cancelled |'
  summary | grep -qF '| `B` | ❌ unknown outcome `` |'
  summary | grep -qF '| `C` | ❌ unknown outcome `maybe` |'
  summary | grep -q 'packages evidence: ❌ FAILED'
}

@test "(c) validations that did not run (all skipped) are INCOMPLETE, not verified" {
  use_pnpm
  default_guardrails
  VALIDATIONS=$'Tests=skipped' run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ⏭️ INCOMPLETE'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "(c) no validation reported to the block is a defect shown in red, never a quiet pass" {
  use_pnpm
  default_guardrails
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -q 'No validation outcome was reported'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

# --- (d) a dependency that is not pinned to a Release ----------------------------------------------------------------------------------
@test "(d) a range is red: not an exact version (and the lockfile origin is not a Release URL either)" {
  printf '{ "name": "app", "dependencies": { "@nextep/cdk-guardrails": "^0.1.0" } }\n' >package.json
  cat >pnpm-lock.yaml <<'YAML'
lockfileVersion: '9.0'
importers:
  .:
    dependencies:
      '@nextep/cdk-guardrails':
        specifier: ^0.1.0
        version: 0.1.0
packages:
  '@nextep/cdk-guardrails@0.1.0':
    resolution: {integrity: sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==}
YAML
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| no: `^0.1.0` | ❌ not an exact version; origin is not a GitHub Release URL |'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "(d) every non-exact shape is red: tag, wildcard, git, file, comparator" {
  local spec
  for spec in latest '*' '~1.2.3' '>=1.0.0' 'github:example-org/shop#v1.0.0' 'file:../lib.tgz'; do
    : >"$GITHUB_STEP_SUMMARY"
    jq -n --arg s "$spec" '{name: "app", dependencies: {"@nextep/gates": $s}}' >package.json
    printf 'lockfileVersion: '"'9.0'"'\nimporters:\n  .:\n    dependencies:\n      '"'@nextep/gates'"':\n        specifier: x\n        version: 1.0.0\n' >pnpm-lock.yaml
    pass_all
    run "$SCRIPTS/packages-evidence.sh" run
    [ "$status" -eq 0 ]
    summary | grep -q 'not an exact version' || { echo "spec '$spec' was not flagged"; summary; return 1; }
    absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  done
}

@test "(d) a lockfile URL outside the Release pattern is red, naming the problem" {
  use_pnpm
  sed -i 's#https://github.com/example-org/shop/releases/download/v0.1.0#https://mirror.example.net/pkgs#g' pnpm-lock.yaml
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -q '❌ origin is not a GitHub Release URL'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "(d) a Release URL that is not https://github.com is red (http, other host, a path that is not releases/download)" {
  local bad
  for bad in 'http://github.com/example-org/shop/releases/download/v0.1.0/x-0.1.0.tgz' 'https://github.com.example.net/example-org/shop/releases/download/v0.1.0/x-0.1.0.tgz' 'https://github.com/example-org/shop/archive/v0.1.0/x-0.1.0.tgz'; do
    : >"$GITHUB_STEP_SUMMARY"
    use_pnpm
    sed -i "s#$URL#$bad#g" pnpm-lock.yaml
    default_guardrails
    pass_all
    run "$SCRIPTS/packages-evidence.sh" run
    [ "$status" -eq 0 ]
    summary | grep -q 'origin is not a GitHub Release URL' || { echo "'$bad' was accepted"; summary; return 1; }
  done
}

@test "(d) no lockfile in the root is red" {
  printf '{ "name": "app", "dependencies": { "@nextep/cdk-guardrails": "%s" } }\n' "$URL" >package.json
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -q '❌ no lockfile (\./pnpm-lock.yaml)'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "(d) a package missing from the lockfile, and a lockfile that is not YAML, are red" {
  use_pnpm
  printf 'lockfileVersion: '"'9.0'"'\nimporters:\n  .:\n    dependencies: {}\n' >pnpm-lock.yaml
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  summary | grep -q '❌ not found in the lockfile'
  : >"$GITHUB_STEP_SUMMARY"
  printf 'a: [unclosed\n' >pnpm-lock.yaml
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q '❌ the lockfile is unreadable'
}

@test "(d) an integrity-less lockfile entry is red" {
  use_npm
  jq 'del(.packages["node_modules/@nextep/cdk-guardrails"].integrity)' package-lock.json >p.json && mv p.json package-lock.json
  default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  summary | grep -q '❌ no integrity in the lockfile'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "(d) a package.json that is not JSON and mentions a @nextep/ package is shown, not skipped" {
  printf '{ "dependencies": { "@nextep/gates": "1.0.0", \n' >package.json
  : >pnpm-lock.yaml
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'the manifest is not valid JSON'
  summary | grep -q 'packages evidence: ❌ FAILED'
}

# --- discovery on disk -----------------------------------------------------------------------------------------------------------------
@test "discovery: every package.json under the root is read (a workspace), the importer key is its path, and node_modules is not scanned" {
  mkdir -p packages/lib node_modules/@nextep/cdk-guardrails node_modules/other cdk.out
  printf '{ "name": "root", "private": true }\n' >package.json
  printf '{ "name": "lib", "devDependencies": { "@nextep/cdk-guardrails": "%s" } }\n' "$URL" >packages/lib/package.json
  # packages that live in node_modules / cdk.out declare @nextep/ things of their own: they are not the repository's
  printf '{ "name": "other", "dependencies": { "@nextep/ghost": "9.9.9" } }\n' >node_modules/other/package.json
  printf '{ "name": "ghost", "dependencies": { "@nextep/ghost2": "9.9.9" } }\n' >cdk.out/package.json
  integrity="$(jq -r '.packages["node_modules/@nextep/cdk-guardrails"].integrity' "$FX/npm/package-lock.json")"
  cat >pnpm-lock.yaml <<YAML
lockfileVersion: '9.0'
importers:
  .: {}
  packages/lib:
    devDependencies:
      '@nextep/cdk-guardrails':
        specifier: $URL
        version: $URL
packages:
  '@nextep/cdk-guardrails@$URL':
    resolution: {integrity: $integrity, tarball: $URL}
    version: 0.1.0
YAML
  mkdir -p packages/lib/node_modules/.bin
  PROJ="$PROJ/packages/lib" default_guardrails
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF '| `@nextep/cdk-guardrails` | `packages/lib/package.json` (devDependencies) | `0.1.0` |'
  summary | grep -qF '| `@nextep/cdk-guardrails` | `packages/lib` | 3 |'
  absent '@nextep/ghost' "$GITHUB_STEP_SUMMARY"
  summary | grep -q '(2 package.json)'
}

@test "discovery: several install roots, each with its own lockfile; a root without the dependency adds nothing" {
  mkdir -p app infra
  cp "$FX/pnpm/package.json" "$FX/pnpm/pnpm-lock.yaml" app/
  printf '{ "name": "infra" }\n' >infra/package.json
  printf 'lockfileVersion: '"'9.0'"'\nimporters:\n  .: {}\n' >infra/pnpm-lock.yaml
  PROJ="$PROJ/app" default_guardrails
  export INSTALL_DIRS=app,infra
  pass_all
  INSTALL_DIRS=app,infra run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -qF '`app/package.json` (dependencies)'
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF '`app,infra`'
}

@test "discovery: an invalid install-dirs (traversal) is refused by the same rule as the install, and the block says it could not be generated" {
  printf '{ "name": "app" }\n' >package.json
  pass_all
  INSTALL_DIRS='../outside' run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'COULD NOT BE GENERATED'
  absent '✅' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::warning::packages evidence: could not be generated"* ]]
}

# --- the binary ------------------------------------------------------------------------------------------------------------------------
@test "guardrails: not installed is red (the install did not run or failed), not silently omitted" {
  use_pnpm
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -q '❌ not installed'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "guardrails: a binary that fails, or one that lists no rules, is red with the real reason" {
  use_pnpm
  pass_all
  fake_guardrails 3
  run "$SCRIPTS/packages-evidence.sh" run
  summary | grep -qF 'exited with code 3'
  : >"$GITHUB_STEP_SUMMARY"
  fake_guardrails 0 'nothing to see here' ''
  run "$SCRIPTS/packages-evidence.sh" run
  summary | grep -q 'the command listed no rules'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "guardrails: only strictly shaped rule ids reach the summary (a line of free text, a markdown or workflow-command payload, never)" {
  use_pnpm
  pass_all
  fake_guardrails 0 'EX-COST-001  error  title' '::error::boom' '| injected | row |' '`tick` x' 'EX-OK-002 warn y'
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -qF '| 2 | EX-COST-001, EX-OK-002 |'
  absent 'boom' "$GITHUB_STEP_SUMMARY"
  absent 'injected' "$GITHUB_STEP_SUMMARY"
}

@test "guardrails: the binary runs with a clean environment: no secret of the CI is visible to it, and none reaches the summary" {
  use_pnpm
  default_guardrails
  pass_all
  INTERNAL_DENYLIST=acme-internal CODEARTIFACT_AUTH_TOKEN=tok-123 GITHUB_TOKEN=ghs_abc run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  grep -q 'secrets=0' "$FAKE_LOG"
  absent 'acme-internal' "$GITHUB_STEP_SUMMARY"
  absent 'tok-123' "$GITHUB_STEP_SUMMARY"
  absent 'ghs_abc' "$GITHUB_STEP_SUMMARY"
  [[ "$output" != *"acme-internal"* && "$output" != *"tok-123"* ]]
}

# --- text that comes from the repository -----------------------------------------------------------------------------------------------
@test "a spec with a pipe, a backtick or a newline cannot break the table or open markdown: it is neutralised inside a code span" {
  jq -n '{name: "app", dependencies: {"@nextep/gates": "1.0.0|`**x**`\n# h"}}' >package.json
  printf 'lockfileVersion: '"'9.0'"'\nimporters:\n  .:\n    dependencies:\n      '"'@nextep/gates'"':\n        specifier: x\n        version: 1.0.0\n' >pnpm-lock.yaml
  pass_all
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  absent '| h' "$GITHUB_STEP_SUMMARY"
  # exactly one data row for the package, with the pipe replaced
  [ "$(grep -c '@nextep/gates' "$GITHUB_STEP_SUMMARY")" -eq 1 ]
  summary | grep -qF '¦'
  absent '^# h' "$GITHUB_STEP_SUMMARY"
}

# --- (e) it runs, and never breaks the job ---------------------------------------------------------------------------------------------
@test "(e) run never fails the job: an internal error leaves a RED block in the summary and a warning, never nothing and never green" {
  use_pnpm
  default_guardrails
  pass_all
  # no yq on the PATH: the pnpm lockfile cannot be read, which is an internal error of the evidence, not of the repository
  local bin="$BATS_TEST_TMPDIR/nobin"
  mkdir -p "$bin"
  for t in bash env dirname cat mktemp rm grep sed tail tr cut date find sort jq head wc timeout mkdir; do ln -s "$(command -v $t)" "$bin/$t" 2>/dev/null || true; done
  PATH="$bin" run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  summary | grep -q 'packages evidence: ❌ COULD NOT BE GENERATED'
  summary | grep -q 'Treat this run as having NO package evidence'
  absent '✅' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::warning::packages evidence: could not be generated"* ]]
}

@test "(e) a run whose previous step failed still gets its block: the outcome is read from VALIDATIONS, which the workflow takes from steps.<id>.outcome" {
  use_pnpm
  default_guardrails
  # what the workflow passes when 'Test' failed and 'Typecheck' was therefore skipped
  VALIDATIONS=$'Tests (pnpm test)=failure\nTypecheck (pnpm typecheck)=skipped' run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  [ -s "$GITHUB_STEP_SUMMARY" ]
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `Tests (pnpm test)` | ❌ FAILED |'
}

@test "render exits non-zero on an internal error (it is run's child; the tests and a human can see it)" {
  printf '{ "name": "app" }\n' >package.json
  INSTALL_DIRS='../outside' run "$SCRIPTS/packages-evidence.sh" render
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid directory"* ]]
}

@test "an unknown subcommand and an unknown package manager are refused" {
  run "$SCRIPTS/packages-evidence.sh" publish
  [ "$status" -eq 1 ]
  PACKAGE_MANAGER=yarn run "$SCRIPTS/packages-evidence.sh" render
  [ "$status" -eq 1 ]
}

@test "without GITHUB_STEP_SUMMARY the block goes to stdout (local run)" {
  use_pnpm
  default_guardrails
  pass_all
  unset GITHUB_STEP_SUMMARY
  run "$SCRIPTS/packages-evidence.sh" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"packages evidence: ✅ VERIFIED"* ]]
}
