# shellcheck shell=bash
# Fixtures of the packages policy (packages-policy.bats, packages-evidence-findings.bats). Fictional data (example-org / shop); the lockfiles are the
# real pnpm output of test/fixtures/packages-evidence with the version (and the name) replaced.
#
# The tests run the scripts from a COPY of the platform tree whose catalog (`packages:` of contracts/package-profiles.yml) is the one below, so editing
# the real catalog (a reviewed, editorial change: min_version, recommended_version) never changes what these tests prove. The real catalog is
# checked by the gate RK-PROFILES.
#   cdk-guardrails        min 0.3.0  recommended 0.4.0     ecs-private-service  min 0.2.0  recommended 0.3.0     gates  min 0.1.0  recommended 0.1.0

FX="$REPO_ROOT/test/fixtures/packages-evidence"
LOCK_EMPTY="lockfileVersion: '9.0'
importers:
  .: {}
"
CDK_PKG='@nextep/cdk-guardrails'

policy_setup() {
  unset INTERNAL_DENYLIST GATE_FORK_PR CODEARTIFACT_AUTH_TOKEN GITHUB_TOKEN INSTALL_DIRS PACKAGE_MANAGER VALIDATIONS ROOT_KINDS ENVIRONMENT GUARDRAILS_RESULT \
    NEXTEP_GUARDRAILS_MODE GITHUB_OUTPUT
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$GITHUB_STEP_SUMMARY"
  export GITHUB_REPOSITORY=example-org/shop GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_REF=refs/heads/main
  export GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=1
  PLAT="$BATS_TEST_TMPDIR/plat"
  mkdir -p "$PLAT/contracts"
  cp -r "$REPO_ROOT/scripts" "$PLAT/scripts"
  cp "$REPO_ROOT/contracts/package-profiles.yml" "$PLAT/contracts/package-profiles.yml"
  yq -i '.packages = {
    "@nextep/cdk-guardrails": {"min_version": "0.3.0", "recommended_version": "0.4.0"},
    "@nextep/ecs-private-service": {"min_version": "0.2.0", "recommended_version": "0.3.0"},
    "@nextep/gates": {"min_version": "0.1.0", "recommended_version": "0.1.0"}}' "$PLAT/contracts/package-profiles.yml"
  P="$PLAT/scripts"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  cd "$PROJ"
}

summary() { cat "$GITHUB_STEP_SUMMARY"; }
absent() { ! grep -qF -- "$1" "$2"; }

fake_guardrails() { # fake_guardrails <dir> [exit code]: the installed binary of that root
  mkdir -p "$1/node_modules/.bin"
  if [[ ${2:-0} == 0 ]]; then
    cat >"$1/node_modules/.bin/nextep-guardrails" <<'SH'
#!/usr/bin/env bash
echo 'EX-COST-001  error  stages=dev,stg,prod  excepcion=no  Example rule one'
echo 'EX-FIN-002   warn   stages=prod  excepcion=si  Example rule two'
SH
  else
    printf '#!/usr/bin/env bash\nexit %s\n' "$2" >"$1/node_modules/.bin/nextep-guardrails"
  fi
  chmod +x "$1/node_modules/.bin/nextep-guardrails"
}

# pkg_root <dir> <package> <version>: a root that declares and resolves ONE @nextep/* package, installed (node_modules exists)
pkg_root() {
  local dir=$1 name=$2 ver=$3 slug
  slug="${name#@nextep/}"
  mkdir -p "$dir/node_modules"
  sed -e "s#@nextep/cdk-guardrails#$name#g" -e "s#nextep-cdk-guardrails#nextep-$slug#g" -e "s#0\.1\.0#$ver#g" "$FX/pnpm/package.json" >"$dir/package.json"
  sed -e "s#@nextep/cdk-guardrails#$name#g" -e "s#nextep-cdk-guardrails#nextep-$slug#g" -e "s#0\.1\.0#$ver#g" "$FX/pnpm/pnpm-lock.yaml" >"$dir/pnpm-lock.yaml"
}

# iac_root <dir> [version]: an IaC root with the guardrails package at that version (default: the recommended one), installed, with a working binary
iac_root() {
  pkg_root "$1" "$CDK_PKG" "${2:-0.4.0}"
  fake_guardrails "$1"
}

# front_root <dir>: a root with no @nextep/* package and its own empty lockfile
front_root() {
  mkdir -p "$1"
  printf '{ "name": "web", "private": true, "dependencies": { "left-pad": "1.3.0" } }\n' >"$1/package.json"
  printf '%s' "$LOCK_EMPTY" >"$1/pnpm-lock.yaml"
}

# good_repo: the shape of a real caller (an app root and its infra root), everything in order. Policy and evidence find nothing to say.
good_repo() {
  front_root .
  iac_root infra
  export ROOT_KINDS='{".":"frontend","infra":"iac"}' INSTALL_DIRS='.,infra' GUARDRAILS_RESULT=pass
}

# break_<id>: turns the good repository into one that has exactly that finding (and, where a second one is unavoidable, says so)
break_PF-1() { unset ROOT_KINDS; }
break_PF-2() { export ROOT_KINDS='{"infra":"iac"}'; }
break_PF-3() {
  printf '{ "name": "infra", "private": true }\n' >infra/package.json
  printf '%s' "$LOCK_EMPTY" >infra/pnpm-lock.yaml
}
break_PF-4() {
  printf '{}\n' >infra/cdk.json
  export ROOT_KINDS='{".":"frontend","infra":"frontend"}'
}
break_PF-5() { export GUARDRAILS_RESULT=fail; }
break_PF-6() { rm -rf infra/node_modules; }
break_PF-7() { export GUARDRAILS_RESULT=missing; }
break_PF-8() { iac_root infra 0.2.0; }
break_PF-9() { iac_root infra 0.3.5; }

# the ids the table of the spec has (PF-9 is separate: it never blocks)
PF_BLOCKING_IDS=(PF-1 PF-2 PF-3 PF-4 PF-5 PF-6 PF-7 PF-8)

findings_ids() { jq -r '[.[].id] | join(",")' <<<"$1"; }
