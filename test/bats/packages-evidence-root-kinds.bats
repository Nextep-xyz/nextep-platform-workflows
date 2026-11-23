#!/usr/bin/env bats
# scripts/packages-evidence.sh with ROOT_KINDS: the evidence stops being "what the repository declares" and becomes "what the kind requires,
# against what the repository has". The sibling file packages-evidence.bats holds the evidence WITHOUT root-kinds and is not touched: it is the
# regression of K4 (an empty ROOT_KINDS is v1.7.0, byte for byte). Fictional data (example-org / shop); the lockfiles are the real pnpm output
# of test/fixtures/packages-evidence.
#   K3 a root with CDK files that is not declared iac is red     K4 empty = unchanged     K5 honesty (no tick for kinds that require nothing,
#   a missing required package is never green nor n/a)           K7 what comes from the repository is neutralised
#   And always: the step exits 0 (a report never fails the job).

load 'helpers'

URL='https://github.com/example-org/shop/releases/download/v0.1.0/nextep-cdk-guardrails-0.1.0.tgz'
FX="$REPO_ROOT/test/fixtures/packages-evidence"
LOCK_EMPTY="lockfileVersion: '9.0'
importers:
  .: {}
"

setup() {
  unset INTERNAL_DENYLIST GATE_FORK_PR CODEARTIFACT_AUTH_TOKEN GITHUB_TOKEN INSTALL_DIRS PACKAGE_MANAGER VALIDATIONS ROOT_KINDS
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$GITHUB_STEP_SUMMARY"
  export GITHUB_REPOSITORY=example-org/shop GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_REF=refs/heads/main
  export GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=1
  export JOB_WORKFLOW_REF='example-org/platform/.github/workflows/lego-node-ci.yml@refs/tags/v9.9.9'
  export FAKE_LOG="$BATS_TEST_TMPDIR/guardrails.log"
  : >"$FAKE_LOG"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  cd "$PROJ"
}

summary() { cat "$GITHUB_STEP_SUMMARY"; }
pass_all() { export VALIDATIONS=$'Tests=success\nTypecheck=success'; }
run_evidence() { run "$SCRIPTS/packages-evidence.sh" run; [ "$status" -eq 0 ]; }

fake_guardrails() { # fake_guardrails <dir>: the installed binary of that root
  mkdir -p "$1/node_modules/.bin"
  cat >"$1/node_modules/.bin/nextep-guardrails" <<'SH'
#!/usr/bin/env bash
echo 'EX-COST-001  error  stages=dev,stg,prod  excepcion=no  Example rule one'
echo 'EX-FIN-002   warn   stages=prod  excepcion=si  Example rule two'
SH
  chmod +x "$1/node_modules/.bin/nextep-guardrails"
}

# iac_root <dir>: a root that declares and resolves the required package, installed (the good case)
iac_root() {
  mkdir -p "$1"
  cp "$FX/pnpm/package.json" "$FX/pnpm/pnpm-lock.yaml" "$1/"
  fake_guardrails "$1"
}

# front_root <dir>: a root with no @nextep/* package and its own empty lockfile
front_root() {
  mkdir -p "$1"
  printf '{ "name": "web", "private": true, "dependencies": { "left-pad": "1.3.0" } }\n' >"$1/package.json"
  printf '%s' "$LOCK_EMPTY" >"$1/pnpm-lock.yaml"
}

# --- the good case: the shape of the real caller (an app root and its infra root) ---------------------------------------------------------
@test "frontend root + iac root with the required package: VERIFIED, each root with its kind, no manifest counted twice" {
  front_root .
  iac_root infra
  pass_all
  export ROOT_KINDS='{".":"frontend","infra":"iac"}' INSTALL_DIRS='.,infra'
  run_evidence
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF '| Roots scanned | `.` → frontend, `infra` → iac (2 roots, 2 package.json) |'
  summary | grep -q '^### Required by kind'
  summary | grep -qF '| `.` | frontend | — | ➖ no packages are defined for this kind |'
  summary | grep -qF '| `infra` | iac | `@nextep/cdk-guardrails` | ✅ declared and resolved in the lockfile |'
  # the package is listed once, under infra (the root `.` contains infra/package.json but does not own it)
  [ "$(grep -c '^| `@nextep/cdk-guardrails` | `infra/package.json`' "$GITHUB_STEP_SUMMARY")" -eq 1 ]
  summary | grep -qF '| `@nextep/cdk-guardrails` | `infra` | 2 |'
  summary | grep -qF '| `Tests` | ✅ passed |'
}

@test "the same repository without root-kinds counts infra/package.json twice (the v1.7.0 behaviour that root-kinds fixes)" {
  front_root .
  iac_root infra
  pass_all
  INSTALL_DIRS='.,infra' run_evidence
  summary | grep -qF '| Roots scanned | `.,infra` (3 package.json) |'
  absent 'Required by kind' "$GITHUB_STEP_SUMMARY"
}

# --- K4: empty means unchanged -----------------------------------------------------------------------------------------------------------
@test "K4: an empty ROOT_KINDS prints no kind section and the legacy header" {
  iac_root .
  pass_all
  ROOT_KINDS="" run_evidence
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF '| Roots scanned | `.` (1 package.json) |'
  absent 'Required by kind' "$GITHUB_STEP_SUMMARY"
  absent '→' "$GITHUB_STEP_SUMMARY"
}

# --- K5: honesty -------------------------------------------------------------------------------------------------------------------------
@test "K5: a required package that is not declared marks the block red, names the kind, is never green nor n/a, and the step still exits 0" {
  front_root .
  mkdir -p infra
  printf '{ "name": "infra", "private": true }\n' >infra/package.json
  printf '%s' "$LOCK_EMPTY" >infra/pnpm-lock.yaml
  pass_all
  export ROOT_KINDS='{".":"frontend","infra":"iac"}' INSTALL_DIRS='.,infra'
  run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `infra` | iac | `@nextep/cdk-guardrails` | ❌ required by kind iac and not declared |'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  absent 'n/a' "$GITHUB_STEP_SUMMARY"
  absent '✅ passed' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::warning::packages evidence: at least one package or validation is not green"* ]]
}

@test "K5: an iac root that does not exist on disk is a missing required package, not a pass" {
  front_root .
  pass_all
  ROOT_KINDS='{".":"frontend","infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `infra` | iac | `@nextep/cdk-guardrails` | ❌ required by kind iac and not declared |'
}

@test "K5: kinds that require nothing are n/a with their reason, never a tick, even with green validations and a non-required @nextep package evidenced" {
  iac_root .
  pass_all
  # the package is declared and resolved, but nobody asked for it on a frontend root: it proves nothing
  ROOT_KINDS='{".":"frontend"}' run_evidence
  summary | grep -q 'packages evidence: n/a'
  summary | grep -qF 'frontend'
  summary | grep -q 'define no required packages'
  summary | grep -qF '➖ passed (no packages to evidence)'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
  absent '✅ passed' "$GITHUB_STEP_SUMMARY"
  # the package row is information, not evidence of the kind
  summary | grep -qF '`@nextep/cdk-guardrails` | `package.json` (dependencies)'
}

@test "K5: backend, frontend and platform together are n/a and each says it defines nothing; a repository with no manifest at all too" {
  mkdir -p api web tools
  pass_all
  ROOT_KINDS='{"api":"backend","web":"frontend","tools":"platform"}' run_evidence
  summary | grep -q 'packages evidence: n/a'
  [ "$(grep -c '➖ no packages are defined for this kind' "$GITHUB_STEP_SUMMARY")" -eq 3 ]
  absent '✅' "$GITHUB_STEP_SUMMARY"
}

@test "K5: a failed validation stays red under root-kinds, and the n/a case does not hide it" {
  front_root .
  VALIDATIONS='Tests=failure' ROOT_KINDS='{".":"frontend"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `Tests` | ❌ FAILED |'
}

@test "K5: required satisfied but a validation did not run is INCOMPLETE, as before" {
  iac_root infra
  VALIDATIONS='Tests=skipped' ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ⏭️ INCOMPLETE'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "K5: a required package declared with a range is red, and the row says the declaration is the problem" {
  mkdir -p infra
  printf '{ "name": "infra", "dependencies": { "@nextep/cdk-guardrails": "^0.1.0" } }\n' >infra/package.json
  cp "$FX/pnpm/pnpm-lock.yaml" infra/
  fake_guardrails infra
  pass_all
  ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF 'required by kind iac and declared, but with a problem (see Packages)'
  summary | grep -qF 'not an exact version'
}

@test "K5: a required package that is only an in-repo workspace package is red (a Release is what the standard asks for)" {
  mkdir -p infra
  printf '{ "name": "infra", "dependencies": { "@nextep/cdk-guardrails": "workspace:*" } }\n' >infra/package.json
  printf '%s' "$LOCK_EMPTY" >infra/pnpm-lock.yaml
  pass_all
  ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF 'only declared as an in-repo package (not a Release)'
}

@test "a required package declared but not installed is red: the root has no node_modules" {
  mkdir -p infra
  cp "$FX/pnpm/package.json" "$FX/pnpm/pnpm-lock.yaml" infra/
  pass_all
  ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '❌ not installed: `infra/node_modules` does not exist'
}

# --- K3: an iac root that was declared as something else ---------------------------------------------------------------------------------
@test "K3: a root with cdk.json declared frontend is red as an undeclared iac root, even when everything else is green" {
  front_root .
  iac_root infra
  : >infra/cdk.json
  mkdir -p web && front_root web
  pass_all
  ROOT_KINDS='{".":"frontend","infra":"frontend","web":"frontend"}' INSTALL_DIRS='.,infra,web' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `infra` | frontend (via `infra`) | — | ❌ undeclared iac root: it has CDK files and is not declared iac |'
  absent 'VERIFIED' "$GITHUB_STEP_SUMMARY"
}

@test "K3: a root with aws-cdk-lib in its package.json and no cdk.json is detected too" {
  front_root .
  mkdir -p infra
  printf '{ "name": "infra", "devDependencies": { "aws-cdk-lib": "2.150.0" } }\n' >infra/package.json
  pass_all
  ROOT_KINDS='{".":"backend"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `infra` | backend (via `.`) | — | ❌ undeclared iac root'
}

@test "K3: an IaC directory that no declared root contains is red too (forgetting to declare infra is the case this gate exists for)" {
  mkdir -p app infra
  printf '{ "name": "app" }\n' >app/package.json
  : >infra/cdk.json
  pass_all
  ROOT_KINDS='{"app":"frontend"}' run_evidence
  summary | grep -q 'packages evidence: ❌ FAILED'
  summary | grep -qF '| `infra` | (not declared) | — | ❌ undeclared iac root: it has CDK files and no declared root contains it |'
}

@test "K3: CDK files below a root declared iac are fine (the most specific root decides), and cdk.out and node_modules are not looked at" {
  iac_root infra
  mkdir -p infra/stacks infra/cdk.out/asset infra/node_modules/some-lib
  : >infra/stacks/cdk.json
  : >infra/cdk.out/asset/cdk.json
  : >infra/node_modules/some-lib/cdk.json
  pass_all
  ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  absent 'undeclared iac root' "$GITHUB_STEP_SUMMARY"
}

# --- the assignment of manifests to roots ------------------------------------------------------------------------------------------------
@test "a manifest outside every declared root is not counted and the header says how many were left out" {
  front_root .
  iac_root infra
  mkdir -p tools/helper
  printf '{ "name": "helper", "dependencies": { "@nextep/gates": "1.0.0" } }\n' >tools/helper/package.json
  pass_all
  # `.` is not declared: infra is, the root package.json and tools/helper are outside it
  ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -qF '| Roots scanned | `infra` → iac (1 roots, 1 package.json, 2 outside every declared root, not counted) |'
  absent '@nextep/gates' "$GITHUB_STEP_SUMMARY"
}

@test "the most specific declared root wins: a nested root takes its manifests, the outer root keeps the rest" {
  mkdir -p apps/web
  front_root .
  front_root apps/web
  iac_root infra
  pass_all
  ROOT_KINDS='{".":"platform","apps/web":"frontend","infra":"iac"}' INSTALL_DIRS='.,apps/web,infra' run_evidence
  summary | grep -qF '| Roots scanned | `.` → platform, `apps/web` → frontend, `infra` → iac (3 roots, 3 package.json) |'
}

@test "a declared root that install-dirs does not list is still scanned, with its own lockfile" {
  iac_root infra
  pass_all
  ROOT_KINDS='{"infra":"iac"}' INSTALL_DIRS='.' run_evidence
  summary | grep -q 'packages evidence: ✅ VERIFIED'
  summary | grep -qF '| `infra` | iac | `@nextep/cdk-guardrails` | ✅ declared and resolved in the lockfile |'
}

@test "a Python root declared backend is n/a and says no packages are defined for the kind" {
  printf 'flask==3.0.0\n' >requirements.txt
  pass_all
  ROOT_KINDS='{".":"backend"}' INSTALL_DIRS='.' run_evidence
  summary | grep -q 'packages evidence: n/a'
  summary | grep -qF '| `.` | backend | — | ➖ no packages are defined for this kind |'
}

# --- K7: what comes from the repository is neutralised -----------------------------------------------------------------------------------
@test "K7: the roots are printed in code spans, and a hostile key is refused (nothing of it reaches the summary)" {
  front_root .
  pass_all
  ROOT_KINDS='{".":"frontend"}' run_evidence
  summary | grep -qF '`.` → frontend'
  : >"$GITHUB_STEP_SUMMARY"
  ROOT_KINDS='{"`| x":"iac"}' run_evidence
  summary | grep -q 'COULD NOT BE GENERATED'
  absent '| x' "$GITHUB_STEP_SUMMARY"
  [[ "$output" == *"::warning::packages evidence: could not be generated"* ]]
}

@test "K7: a manifest name with a pipe or a backtick stays inside its code span under root-kinds too" {
  mkdir -p infra
  jq -n '{name: "infra", dependencies: {"@nextep/gates": "1.0.0|`**x**`"}}' >infra/package.json
  printf '%s' "$LOCK_EMPTY" >infra/pnpm-lock.yaml
  pass_all
  ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -qF '¦'
  [ "$(grep -c '@nextep/gates' "$GITHUB_STEP_SUMMARY")" -eq 1 ]
}

# --- a bad declaration never fails the job, and never turns green ------------------------------------------------------------------------
@test "a malformed ROOT_KINDS (the validation of the workflow should have stopped it) leaves a red block and exit 0, never green" {
  front_root .
  pass_all
  local v
  for v in 'not json' '{".":"app"}' '{"..":"iac"}' '[]' '{}'; do
    : >"$GITHUB_STEP_SUMMARY"
    ROOT_KINDS="$v" run_evidence
    summary | grep -q 'COULD NOT BE GENERATED' || { echo "'$v': $(summary)"; return 1; }
    absent '✅' "$GITHUB_STEP_SUMMARY"
  done
}

@test "npm works with root-kinds too: the lockfile of each root is package-lock.json" {
  mkdir -p infra
  cp "$FX/npm/package.json" "$FX/npm/package-lock.json" infra/
  fake_guardrails infra
  pass_all
  PACKAGE_MANAGER=npm ROOT_KINDS='{"infra":"iac"}' run_evidence
  summary | grep -q 'packages evidence: ✅ VERIFIED'
}
