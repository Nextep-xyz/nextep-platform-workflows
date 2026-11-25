#!/usr/bin/env bats
# scripts/packages-evidence.sh findings / iac-roots: the verdict of the packages policy, read from the disk by the SAME function that renders the
# block, so the block and the verdict cannot disagree. Fictional data (example-org / shop), controlled catalog (policy-helpers.bash).
#   E8   for each fixture, a red mark of the block on the axes of the policy (a required package, an undeclared IaC root, the guardrails binary)
#        is a finding, and the other way round. Pin defects of a package nobody requires (a range, a URL that is not a Release) stay red in the
#        block and are NOT findings: they are the evidence's own business, not a rule of the policy (declared in the runbook).
#   K4  (regression) the block without root-kinds is untouched: the sibling files packages-evidence*.bats pass without being modified.
#   The findings do not depend on the environment (dev, stg, prod): the mode is the policy's business.

load 'helpers'
load 'policy-helpers'

setup() { policy_setup; }

findings() { run "$P/packages-evidence.sh" findings; [ "$status" -eq 0 ] || { echo "$output"; return 1; }; }
block() {
  export VALIDATIONS=$'Tests=success\nTypecheck=success'
  : >"$GITHUB_STEP_SUMMARY"
  run "$P/packages-evidence.sh" run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# the red marks of the block on the axes of the policy
policy_axis_red() {
  grep -qE '❌ required by kind|❌ not installed|undeclared iac root|❌ the command listed no rules|exited with code' "$GITHUB_STEP_SUMMARY"
}
# the findings of the same axes
policy_axis_findings() { jq -e '[.[] | select(.id == "PF-3" or .id == "PF-4" or .id == "PF-5" or .id == "PF-6")] | length > 0' >/dev/null <<<"$1"; }

@test "the good repository has no finding: the findings are an empty JSON array and the block is VERIFIED" {
  good_repo
  findings
  [ "$output" = '[]' ]
  block
  summary | grep -q 'packages evidence: ✅ VERIFIED'
}

@test "each broken repository has exactly the finding it is built for, and the object carries id, root, kind and a detail" {
  declare -A want=([PF-1]=PF-1 [PF-2]=PF-2 [PF-3]=PF-3 [PF-4]=PF-4 [PF-6]=PF-6 [PF-8]=PF-8 [PF-9]=PF-9)
  local id
  for id in "${!want[@]}"; do
    rm -rf "$PROJ"/* "$PROJ"/.[!.]* 2>/dev/null || true
    good_repo
    "break_$id"
    findings
    [ "$(findings_ids "$output")" = "${want[$id]}" ] || { echo "$id gave: $output"; return 1; }
    jq -e '.[0] | has("id") and has("root") and has("kind") and has("detail") and (.detail | length > 0)' >/dev/null <<<"$output"
  done
}

@test "E8: the block and the findings agree on every fixture (the axes of the policy), and a package with a pin defect that nobody requires is the declared exception" {
  local name
  for name in good PF-3 PF-4 PF-6 guard-exit guard-norules workspace pin-required pin-optional; do
    rm -rf "$PROJ"/* "$PROJ"/.[!.]* 2>/dev/null || true
    good_repo
    case "$name" in
      good) ;;
      PF-3 | PF-4 | PF-6) "break_$name" ;;
      guard-exit) fake_guardrails infra 3 ;;
      guard-norules) printf '#!/usr/bin/env bash\nexit 0\n' >infra/node_modules/.bin/nextep-guardrails ;;
      workspace) sed -i 's#"https://[^"]*"#"workspace:*"#' infra/package.json ;;
      pin-required) sed -i 's#"https://[^"]*"#"^0.4.0"#' infra/package.json ;;
      pin-optional)
        mkdir -p api
        printf '{ "name": "api", "private": true, "dependencies": { "@nextep/gates": "^0.1.0" } }\n' >api/package.json
        printf '%s' "$LOCK_EMPTY" >api/pnpm-lock.yaml
        export ROOT_KINDS='{".":"frontend","infra":"iac","api":"backend"}' INSTALL_DIRS='.,infra,api'
        ;;
    esac
    findings
    local json=$output red=0 fnd=0
    block
    if policy_axis_red; then red=1; fi
    if policy_axis_findings "$json"; then fnd=1; fi
    if [[ $name == pin-optional ]]; then
      # the declared exception: red in the block, no finding of the policy
      [ "$red" -eq 0 ] && [ "$fnd" -eq 0 ] || { echo "$name: red=$red findings=$fnd $json"; return 1; }
      summary | grep -q 'packages evidence: ❌ FAILED'
    else
      [ "$red" -eq "$fnd" ] || { echo "$name: block red=$red but findings=$fnd: $json"; summary; return 1; }
    fi
    if [[ $name != good ]]; then
      [ "$(jq 'length' <<<"$json")" -gt 0 ] || { [[ $name == pin-optional ]] || { echo "$name has no finding"; return 1; }; }
    fi
  done
}

@test "E8: the guardrails binary that is not installed, that exits non-zero or that lists no rules are PF-6 and PF-5" {
  good_repo
  rm infra/node_modules/.bin/nextep-guardrails
  findings
  [ "$(findings_ids "$output")" = PF-6 ]
  fake_guardrails infra 3
  findings
  [ "$(findings_ids "$output")" = PF-5 ]
  jq -e '.[0].detail | test("exited with code 3")' >/dev/null <<<"$output"
  printf '#!/usr/bin/env bash\nexit 0\n' >infra/node_modules/.bin/nextep-guardrails
  findings
  [ "$(findings_ids "$output")" = PF-5 ]
  jq -e '.[0].detail | test("listed no rules")' >/dev/null <<<"$output"
}

@test "a required package that is declared but whose root (and every root above it) has no lockfile is PF-6 (not installed), not PF-3" {
  good_repo
  rm infra/pnpm-lock.yaml pnpm-lock.yaml
  findings
  [ "$(findings_ids "$output")" = PF-6 ]
}

@test "a required package declared only as an in-repo (workspace) package is PF-3" {
  good_repo
  sed -i 's#"https://[^"]*"#"workspace:*"#' infra/package.json
  findings
  [ "$(findings_ids "$output")" = PF-3 ]
  jq -e '.[0].detail | test("in-repo")' >/dev/null <<<"$output"
}

# --- no root-kinds ---------------------------------------------------------------------------------------------------------------------------
@test "without root-kinds the finding is PF-1, with what the disk shows (CDK files) in its detail; the catalog is still evaluated" {
  front_root .
  iac_root infra 0.2.0
  printf '{}\n' >infra/cdk.json
  export INSTALL_DIRS='.,infra'
  unset ROOT_KINDS
  findings
  [ "$(findings_ids "$output")" = "PF-1,PF-8" ] || { echo "$output"; return 1; }
  [ "$(jq -r '.[0].detail' <<<"$output")" = "root 'infra' has CDK files, declare it iac" ]
}

@test "without root-kinds and without anything to detect the detail says there is nothing declared" {
  front_root .
  export INSTALL_DIRS='.'
  unset ROOT_KINDS
  findings
  [ "$(jq -r '.[0].detail' <<<"$output")" = "no root-kinds declared" ]
}

@test "a manifest that declares aws-cdk-lib marks its directory as an IaC root even without a cdk.json (as in the block)" {
  front_root .
  mkdir -p app
  printf '{ "name": "app", "private": true, "dependencies": { "aws-cdk-lib": "2.0.0" } }\n' >app/package.json
  printf '%s' "$LOCK_EMPTY" >app/pnpm-lock.yaml
  export ROOT_KINDS='{".":"frontend"}' INSTALL_DIRS='.'
  findings
  [ "$(findings_ids "$output")" = PF-4 ]
  [ "$(jq -r '.[0].root' <<<"$output")" = app ]
}

# --- iac-roots ---------------------------------------------------------------------------------------------------------------------------------
@test "iac-roots prints the roots declared iac and the ones detected by CDK files, one per line, without repeats" {
  good_repo
  printf '{}\n' >infra/cdk.json
  mkdir -p tools
  printf '{}\n' >tools/cdk.json
  run "$P/packages-evidence.sh" iac-roots
  [ "$status" -eq 0 ]
  [ "$output" = $'infra\ntools' ]
  good_repo
  rm -rf infra/cdk.json tools
  run "$P/packages-evidence.sh" iac-roots
  [ "$output" = infra ]
  front_root .
  export ROOT_KINDS='{".":"frontend"}' INSTALL_DIRS='.'
  run "$P/packages-evidence.sh" iac-roots
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- shape and independence ------------------------------------------------------------------------------------------------------------------
@test "the findings are deterministic and do not depend on the environment or on the validations of the run" {
  good_repo
  break_PF-3
  mkdir -p api
  printf '{}\n' >api/cdk.json
  export ROOT_KINDS='{".":"frontend","infra":"iac","api":"frontend"}' INSTALL_DIRS='.,infra,api'
  findings
  local first=$output
  ENVIRONMENT=prod VALIDATIONS='Tests=failure' findings
  [ "$output" = "$first" ]
  ENVIRONMENT=dev findings
  [ "$output" = "$first" ]
  [ "$(findings_ids "$first")" = "PF-3,PF-4" ]
}

@test "a malformed root-kinds is an error (non-zero exit, nothing on stdout), never a quiet empty verdict" {
  good_repo
  ROOT_KINDS='not json' run "$P/packages-evidence.sh" findings
  [ "$status" -ne 0 ]
  ROOT_KINDS='{".":"library"}' run "$P/packages-evidence.sh" findings
  [ "$status" -ne 0 ]
  ROOT_KINDS='{".":"frontend"}' INSTALL_DIRS='../x' run "$P/packages-evidence.sh" findings
  [ "$status" -ne 0 ]
}

@test "a catalog entry that is not a plain X.Y.Z (or has no recommended_version) is an error, never a silent skip" {
  good_repo
  yq -i '.packages."@nextep/gates".min_version = "latest"' "$PLAT/contracts/package-profiles.yml"
  run "$P/packages-evidence.sh" findings
  [ "$status" -ne 0 ]
  [[ "$output" == *"catalog entry '@nextep/gates'"* ]]
  yq -i '.packages."@nextep/gates".min_version = "0.1.0" | del(.packages."@nextep/gates".recommended_version)' "$PLAT/contracts/package-profiles.yml"
  run "$P/packages-evidence.sh" findings
  [ "$status" -ne 0 ]
}

@test "a PE_EMIT in the environment does not turn the block into the verdict (the mode comes from the subcommand only)" {
  good_repo
  PE_EMIT=findings run "$P/packages-evidence.sh" render
  [ "$status" -eq 0 ]
  [[ "$output" == "## @nextep/* packages evidence:"* ]]
}

@test "the block itself is the same with and without the verdict code: a render prints no finding id" {
  good_repo
  break_PF-3
  block
  summary | grep -q 'required by kind iac and not declared'
  ! summary | grep -q 'PF-'
}

@test "E11: what the findings carry from the repository is reduced to a safe alphabet (a directory name with a pipe, backtick, percent or newline)" {
  good_repo
  mkdir -p 'evil|`x%0A'
  printf '{}\n' >'evil|`x%0A/cdk.json'
  findings
  jq -e '[.[] | .root] | all(test("^[A-Za-z0-9._/?-]*$"))' >/dev/null <<<"$output"
  [[ "$output" != *'`'* && "$output" != *'evil|'* ]]
  [ "$(jq -r '.[0].root' <<<"$output")" = 'evil??x?0A' ]
}
