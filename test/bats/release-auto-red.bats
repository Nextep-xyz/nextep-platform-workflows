#!/usr/bin/env bats
# The gates of the release automation, verified IN RED (like gates-red.bats does for the rest): each test copies this repository to a
# temporary GATES_ROOT, breaks ONE thing, runs the real gate against the copy and checks that it fails AND names the culprit file.
# The real tree is never touched.

bats_require_minimum_version 1.5.0
load 'helpers'

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX"
  (cd "$REPO_ROOT" && tar --exclude=.git --exclude=node_modules -cf - .) | (cd "$FX" && tar -xf -)
  export GATES_ROOT="$FX"
  WF="$FX/.github/workflows/release.yml"
}

# red <gate file> <test-name filter> <fragment>...: the gate must fail and its output must contain every fragment.
red() {
  local file=$1 filter=$2 frag
  shift 2
  run bats -f "$filter" "$REPO_ROOT/test/gates/$file"
  [ "$status" -ne 0 ] || { echo "the gate passed on a broken tree:"; echo "$output"; return 1; }
  for frag in "$@"; do
    [[ $output == *"$frag"* ]] || { echo "expected '$frag' in:"; echo "$output"; return 1; }
  done
}

green() {
  run bats -f "$2" "$REPO_ROOT/test/gates/$1"
  [ "$status" -eq 0 ] || { echo "the gate fails on the intact copy:"; echo "$output"; return 1; }
}

@test "the intact copy passes every release-automation gate (the red tests below break exactly one thing each)" {
  green release-auto.bats 'RA5:'
  green release-auto.bats 'RA7:'
  green release-auto.bats 'RA9:'
  green release-auto.bats 'RA10:'
  green release-pins.bats 'T10: release.yml'
}

# --- RA5 ----------------------------------------------------------------------------------------------------------------------------

@test "RA5 red: a step that builds the release tree without the dry_run condition is named" {
  yq -i 'del(.jobs.release.steps[] | select(.name == "Build the release tree") | .if)' "$WF"
  red release-auto.bats 'RA5:' "release.yml: step 'Build the release tree'" "would have effects"
}

@test "RA5 red: a step that commits, tags and pushes with only half of the condition is named" {
  yq -i '(.jobs.release.steps[] | select(.name == "Commit, tag and move the major alias") | .if) = "steps.plan.outputs.release == '"'"'true'"'"'"' "$WF"
  red release-auto.bats 'RA5:' "release.yml: step 'Commit, tag and move the major alias'"
}

@test "RA5 red: the suite step without the condition is named, and a workflow without the dry_run input is named" {
  yq -i 'del(.jobs.release.steps[] | select(.name == "Run the suite on the commit to release") | .if) | del(.on.workflow_dispatch.inputs.dry_run)' "$WF"
  red release-auto.bats 'RA5:' "release.yml: step 'Run the suite on the commit to release'" "release.yml: has no 'dry_run' input"
}

@test "RA5 red: with no release workflow on disk the gate fails instead of passing" {
  rm "$WF"
  red release-auto.bats 'RA5:' "0 workflows that cut releases were discovered"
}

# --- RA7 ----------------------------------------------------------------------------------------------------------------------------

@test "RA7 red: an entry only in docs/release-surface.yml, and one only in the script, are named in their file" {
  yq -i '.["non-surface"] += [{"pattern": "only-in-yml/**", "reason": "x"}]' "$FX/docs/release-surface.yml"
  sed -i "s#^NON_SURFACE=(\$#NON_SURFACE=(\n  'only-in-script/**'#" "$FX/scripts/next-version.sh"
  red release-auto.bats 'RA7:' "docs/release-surface.yml: lists 'only-in-yml/**' but scripts/next-version.sh does not" \
    "scripts/next-version.sh: lists 'only-in-script/**' but docs/release-surface.yml does not"
}

@test "RA7 red: an entry declared in both places that matches no file is reported as stale" {
  yq -i '.["non-surface"] += [{"pattern": "gone/**", "reason": "x"}]' "$FX/docs/release-surface.yml"
  sed -i "s#^NON_SURFACE=(\$#NON_SURFACE=(\n  'gone/**'#" "$FX/scripts/next-version.sh"
  red release-auto.bats 'RA7:' "docs/release-surface.yml: the entry 'gone/**' matches no versioned file"
}

@test "RA7 red: an entry without a reason and a yml that is not valid YAML are named" {
  yq -i '(.["non-surface"][] | select(.pattern == "docs/**") | .reason) = ""' "$FX/docs/release-surface.yml"
  red release-auto.bats 'RA7:' "docs/release-surface.yml: the entry 'docs/**' has no reason"
  printf 'non-surface:\n  - pattern: "docs/**"\n    reason: a: b\n' >"$FX/docs/release-surface.yml"
  red release-auto.bats 'RA7:' "docs/release-surface.yml: is not valid YAML"
}

@test "RA7 red: when every file on disk is non-surface the gate fails instead of passing" {
  # delete exactly the files that the script itself classifies as surface
  (cd "$FX" && find . -type f -not -path './.git/*' -print0 | sed -z 's#^\./##' | bash scripts/next-version.sh --classify |
    awk -F'\t' '$1 == "surface" { print $2 }' | xargs -r -d '\n' rm -f)
  red release-auto.bats 'RA7:' "0 surface files discovered on disk"
}

# --- RA9 ----------------------------------------------------------------------------------------------------------------------------

@test "RA9 red: a list of jobs written by hand in the guard script is named" {
  sed -i 's#^require_env SOURCE_SHA GITHUB_REPOSITORY$#required=(static-analysis tests secret-scan)\nrequire_env SOURCE_SHA GITHUB_REPOSITORY#' "$FX/scripts/ci/require-green-ci.sh"
  red release-auto.bats 'RA9:' "scripts/ci/require-green-ci.sh: names the job 'static-analysis'" "never written by hand"
}

@test "RA9 red: a guard that stops reading self-ci.yml is named" {
  sed -i 's#self-ci\.yml#other-ci.yml#g' "$FX/scripts/ci/require-green-ci.sh"
  red release-auto.bats 'RA9:' "scripts/ci/require-green-ci.sh: does not read the required jobs from self-ci.yml"
}

@test "RA9 red: a guard step without the plan condition and a missing guard script are named" {
  yq -i 'del(.jobs.release.steps[] | select(.name == "Require a green CI on the commit") | .if)' "$WF"
  red release-auto.bats 'RA9:' "release.yml: has no step that runs scripts/ci/require-green-ci.sh, or it is not gated"
  rm "$FX/scripts/ci/require-green-ci.sh"
  red release-auto.bats 'RA9:' "scripts/ci/require-green-ci.sh: does not exist"
}

@test "RA9 red: a guard that runs after the suite is named" {
  yq -i '.jobs.release.steps |= (. as $s | ([$s[] | select(.name != "Require a green CI on the commit")]) + [$s[] | select(.name == "Require a green CI on the commit")])' "$WF"
  red release-auto.bats 'RA9:' "release.yml: the CI guard does not run BEFORE"
}

@test "RA9 red: a job of the guard step written by hand in its env is named" {
  yq -i '(.jobs.release.steps[] | select(.name == "Require a green CI on the commit") | .env.REQUIRED) = "static-analysis"' "$WF"
  red release-auto.bats 'RA9:' "release.yml: the CI guard step names the job 'static-analysis' by hand"
}

# --- RA10 ---------------------------------------------------------------------------------------------------------------------------

@test "RA10 red: widening the permissions of the release job is named" {
  yq -i '.jobs.release.permissions."pull-requests" = "write"' "$WF"
  red release-auto.bats 'RA10:' "release.yml: job 'release' cuts releases and must hold exactly {contents: write, checks: read}"
}

@test "RA10 red: RELEASE_TOKEN in a step other than the checkout, and the job token outside the guard, are named" {
  yq -i '(.jobs.release.steps[] | select(.name == "Verify the published tags") | .env.PUSH_TOKEN) = "${{ secrets.RELEASE_TOKEN }}"' "$WF"
  yq -i '(.jobs.release.steps[] | select(.name == "Build the release tree") | .env.GH_TOKEN) = "${{ github.token }}"' "$WF"
  red release-auto.bats 'RA10:' "release.yml: step 'Verify the published tags' uses RELEASE_TOKEN outside the token of actions/checkout" \
    "release.yml: step 'Build the release tree' uses the job token"
}

@test "RA10 red: workflow-level permissions are named" {
  yq -i '.permissions.contents = "write"' "$WF"
  red release-auto.bats 'RA10:' "release.yml: workflow-level 'permissions:' is forbidden"
}

# --- T10 ----------------------------------------------------------------------------------------------------------------------------

@test "T10 red: tagging from the raw input instead of the resolved version is named" {
  yq -i '(.jobs.release.steps[] | select(.name == "Commit, tag and move the major alias") | .env.VERSION) = "${{ inputs.version }}"' "$WF"
  red release-pins.bats 'T10: release.yml' "release.yml: the step that creates tags takes VERSION from '\${{ inputs.version }}'"
}

@test "T10 red: a version guard that moved after the first git tag, a tag of an unexpected shape and a missing guard are named" {
  sed -i 's#git tag -a "v${VERSION}" -m "v${VERSION}"#git tag -a "v${VERSION}" -m "v${VERSION}"; git tag "v${VERSION%.*}"#' "$WF"
  red release-pins.bats 'T10: release.yml' "creates or pushes a tag of an unexpected shape"
  cp "$REPO_ROOT/.github/workflows/release.yml" "$WF"
  sed -i 's#\[\[ \$VERSION =~ \^\[0-9\]+\\.\[0-9\]+\\.\[0-9\]+\$ \]\]#true#' "$WF"
  red release-pins.bats 'T10: release.yml' "release.yml: the version guard is not" "does not check"
}
