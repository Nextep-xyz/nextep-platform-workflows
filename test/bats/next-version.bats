#!/usr/bin/env bats
# scripts/next-version.sh: decides whether there is something to release and which version it gets (guards RA1, RA3, RA4, RA6,
# RA8, RA12 of the release-automation spec). Every test builds a throwaway git repository with the canonical release tag
# (helpers.bash: make_release_repo); the real repository is never read. Fictional data only.

bats_require_minimum_version 1.5.0
load 'helpers'

setup() {
  make_release_repo
  cd "$RR"
}

# fresh: a brand-new repository inside the same test (a second scenario that must not see the first one).
fresh() {
  rm -rf "$BATS_TEST_TMPDIR/repo"
  make_release_repo
  cd "$RR"
}

nv() { run --separate-stderr bash "$SCRIPTS/next-version.sh" "$@"; }
kv() { grep -E "^$1=" <<<"$output" | cut -d= -f2-; }
report() { cat "$NEXT_VERSION_REPORT"; }

# A negated command in the middle of a bats test (`! grep ...`) never fails the test (errexit does not apply to `!`): a negative
# assertion has to return 1 by hand, or the test passes without proving anything.
report_lacks() { # report_lacks <literal>
  if grep -qF -- "$1" "$NEXT_VERSION_REPORT"; then echo "the report contains '$1':"; cat "$NEXT_VERSION_REPORT"; return 1; fi
}
no_file() { # no_file <path>...
  local p
  for p in "$@"; do [[ ! -e $p ]] || { echo "unexpected file: $p (a commit message was evaluated)"; return 1; }; done
}

# --- the plain levels ---------------------------------------------------------------------------------------------------------

@test "a fix on the surface is a patch: 1.0.0 -> 1.0.1, and the machine output is exact" {
  rr_commit "fix: Repair the demo script" scripts/run.sh
  nv --bump auto
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'release=true\nlast=1.0.0\nbase=%s\nnext=1.0.1\nlevel=patch' "$(rr_git rev-parse v1.0.0^)")" ]
}

@test "a feat on the surface is a minor: 1.0.0 -> 1.1.0" {
  rr_commit "feat: Add a demo capability" scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  [ "$(kv next)" = 1.1.0 ]
  [ "$(kv level)" = minor ]
}

@test "ref, infra, chore and docs that touch the surface are patches" {
  local t
  for t in ref infra chore docs; do
    rr_commit "$t: Touch the composite" .github/actions/demo/action.yml
  done
  nv
  [ "$status" -eq 0 ]
  [ "$(kv level)" = patch ]
  [ "$(kv next)" = 1.0.1 ]
}

@test "a feat that touches only docs does not raise the level (only the commits on the surface count)" {
  rr_commit "feat: Document the demo" docs/notes.md
  rr_commit "fix: Repair the demo script" scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  [ "$(kv level)" = patch ]
}

@test "an unrecognised prefix is a patch WITH a warning in the report" {
  rr_commit "tweak the thing" scripts/run.sh
  rr_commit "perf: Speed it up" scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  [ "$(kv level)" = patch ]
  report | grep -q 'no recognised type prefix'
  report | grep -q "unrecognised commit type 'perf'"
}

@test "a scope in the subject is accepted: feat(demo): ... is a minor" {
  rr_commit "feat(demo): Add a capability" scripts/run.sh
  nv
  [ "$(kv level)" = minor ]
}

# --- RA6: no surface, no release -----------------------------------------------------------------------------------------------

@test "RA6: changes only in docs, tests and root markdown give release=false (exit 0)" {
  rr_commit "docs: Update the notes" docs/notes.md
  rr_commit "docs: Update the readme" README.md
  rr_commit "feat: Add a test" test/t.bats
  rr_commit "fix: Edit the self-ci workflow" .github/workflows/self-ci.yml
  nv
  [ "$status" -eq 0 ]
  [ "$(kv release)" = false ]
  [ -z "$(kv next)" ]
  report | grep -q 'nothing to release'
}

@test "RA6: a NEW file outside the non-surface list triggers a release by default" {
  rr_commit "chore: Add a new thing" extras/new-thing.txt
  nv
  [ "$status" -eq 0 ]
  [ "$(kv release)" = true ]
  [ "$(kv level)" = patch ]
}

@test "right after a release (the tag is on a child of HEAD) there is nothing to release: the second queued dispatch does nothing" {
  rr_commit "feat: Add a demo capability" scripts/run.sh
  rr_release 1.1.0
  nv
  [ "$status" -eq 0 ]
  [ "$(kv release)" = false ]
}

# --- the mechanical floor from the contracts ------------------------------------------------------------------------------------

@test "floor: an additive contract change is a minor even if the commit says fix" {
  rr_edit_contract '.inputs.extra = {"type": "string", "default": ""}' "fix: Adjust the demo"
  nv
  [ "$status" -eq 0 ]
  [ "$(kv level)" = minor ]
  [ "$(kv next)" = 1.1.0 ]
  report | grep -q 'new optional input: extra'
}

@test "floor: new optional secret, new output, new job, changed default and a new contract are minors" {
  rr_edit_contract '.secrets.TOKEN = {"required": false}' "fix: a"
  nv; [ "$(kv level)" = minor ]; report | grep -q 'new optional secret: TOKEN'
  rr_edit_contract '.outputs.other = {}' "fix: b"
  nv; report | grep -q 'new output: other'
  rr_edit_contract '.jobs += ["verify"]' "fix: c"
  nv; report | grep -q 'new job: verify'
  rr_edit_contract '.inputs.flavor.default = "b"' "fix: d"
  nv; report | grep -q 'input default changed: flavor'
  cp "$RR/contracts/lego-aws-demo.contract.yml" "$RR/contracts/lego-aws-other.contract.yml"
  rr_git add -A; rr_git commit -q -m "fix: e"
  nv; report | grep -q 'lego-aws-other.contract.yml: new contract'
  [ "$(kv level)" = minor ]
}

@test "floor: a default that changes from false to true is detected (false is not 'no default')" {
  rr_edit_contract '.inputs.dry.default = true' "fix: Flip a default"
  nv
  [ "$(kv level)" = minor ]
  report | grep -q 'input default changed: dry'
}

@test "floor: relaxing a required input to optional is not a break" {
  rr_edit_contract '.inputs.project.required = false' "fix: Relax"
  nv
  [ "$status" -eq 0 ]
  [ "$(kv level)" = patch ]
}

@test "floor: --bump patch below the floor is an error, --bump minor over a fix is a minor, --bump patch over a feat stays minor" {
  rr_edit_contract '.inputs.extra = {"type": "string", "default": ""}' "fix: Adjust"
  nv --bump patch
  [ "$status" -ne 0 ]
  [[ $stderr == *"below the mechanical floor minor"* ]]
  [[ $stderr == *"new optional input: extra"* ]]

  fresh
  rr_commit "fix: Repair" scripts/run.sh
  nv --bump minor
  [ "$status" -eq 0 ]
  [ "$(kv level)" = minor ]
  [ "$(kv next)" = 1.1.0 ]

  fresh
  rr_commit "feat: Add" scripts/run.sh
  nv --bump patch
  [ "$status" -eq 0 ]
  [ "$(kv level)" = minor ]
}

# --- RA1: auto never produces a major ----------------------------------------------------------------------------------------------

# major_case <description> <yq expression> <fragment expected in stderr>
major_case() {
  rr_edit_contract "$2" "feat: $1"
  nv
  [ "$status" -ne 0 ] || { echo "'$1' was not refused"; return 1; }
  [[ $stderr == *"never produces a major"* ]] || { echo "no 'never produces a major' for '$1': $stderr"; return 1; }
  [[ $stderr == *"contracts/lego-aws-demo.contract.yml"* ]] || { echo "the culprit file is not named for '$1': $stderr"; return 1; }
  [[ $stderr == *"$3"* ]] || { echo "'$3' not named for '$1': $stderr"; return 1; }
  [[ $stderr == *"trust policies"* ]]
  [[ -z $(kv release) ]]
  report | grep -q 'never produces a major'
}

@test "RA1: a removed input is refused, naming the file and the key" {
  major_case "remove an input" 'del(.inputs.flavor)' "input removed or renamed: flavor"
}
@test "RA1: a renamed input is refused" {
  major_case "rename an input" '.inputs.style = .inputs.flavor | del(.inputs.flavor)' "input removed or renamed: flavor"
}
@test "RA1: a changed input type is refused" {
  major_case "retype an input" '.inputs.flavor.type = "number"' "input type changed: flavor"
}
@test "RA1: a new required input without a default is refused" {
  major_case "add a required input" '.inputs.must = {"type": "string", "required": true}' "new required input without a default: must"
}
@test "RA1: an input that becomes required is refused" {
  major_case "require an input" '.inputs.flavor.required = true' "input became required: flavor"
}
@test "RA1: a removed output is refused" {
  major_case "remove an output" 'del(.outputs.result)' "output removed or renamed: result"
}
@test "RA1: a removed job is refused because it would break the required checks" {
  major_case "remove a job" '.jobs = ["build"]' "job removed or renamed"
}
@test "RA1: a new required secret is refused" {
  major_case "add a required secret" '.secrets.KEY = {"required": true}' "new required secret: KEY"
}

@test "RA1: a deleted contract and a deleted workflow are refused" {
  rr_git rm -q contracts/lego-aws-demo.contract.yml
  rr_git commit -q -m "fix: Drop the contract"
  nv
  [ "$status" -ne 0 ]
  fresh
  rr_git rm -q .github/workflows/lego-aws-demo.yml
  rr_git commit -q -m "fix: Drop the workflow"
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *".github/workflows/lego-aws-demo.yml: workflow deleted"* ]]
}

@test "RA1: a breaking marker in a commit is refused: 'feat!:', 'fix(scope)!:' and a BREAKING CHANGE footer" {
  rr_commit "feat!: Rework the demo" scripts/run.sh
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"breaking commit"* && $stderr == *"Rework the demo"* ]]

  fresh
  rr_commit "fix(core)!: Rework the demo" scripts/run.sh
  nv
  [ "$status" -ne 0 ]

  fresh
  RR_BODY=$'Some explanation.\n\nBREAKING CHANGE: the demo changed' rr_commit "feat: Rework the demo" scripts/run.sh
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"BREAKING CHANGE footer"* ]]
}

@test "RA1: a breaking marker on a commit that touches only docs does not count" {
  rr_commit "feat!: Rewrite the notes" docs/notes.md
  rr_commit "fix: Repair" scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  [ "$(kv level)" = patch ]
}

@test "RA1: with an explicit version the breaking change is allowed and the level is the implied one" {
  rr_edit_contract 'del(.inputs.flavor)' "feat: Remove an input"
  nv --version 2.0.0
  [ "$status" -eq 0 ]
  [ "$(kv release)" = true ]
  [ "$(kv next)" = 2.0.0 ]
  [ "$(kv level)" = major ]
}

@test "an explicit version below the computed level is accepted with a warning in the report" {
  rr_commit "feat: Add" scripts/run.sh
  nv --version 1.0.5
  [ "$status" -eq 0 ]
  [ "$(kv level)" = patch ]
  report | grep -q 'the explicit version 1.0.5 is a patch over 1.0.0 but the changes compute a minor'
}

# --- RA3: monotonicity and the version syntax ------------------------------------------------------------------------------------

@test "RA3: an explicit version lower than the last release is refused (1.2.5 with v1.3.0 cut)" {
  rr_commit "feat: Add" scripts/run.sh; rr_release 1.3.0
  rr_commit "fix: Repair" scripts/run.sh
  nv --version 1.2.5
  [ "$status" -ne 0 ]
  [[ $stderr == *"not greater than the last release v1.3.0"* ]]
}

@test "RA3: an existing version is refused, even when nothing changed" {
  rr_commit "feat: Add" scripts/run.sh; rr_release 1.3.0
  nv --version 1.3.0
  [ "$status" -ne 0 ]
  [[ $stderr == *"v1.3.0 already exists"* ]]
}

@test "RA3: versions order by number, not by text: v1.10.0 is higher than v1.9.0" {
  rr_commit "feat: Add" scripts/run.sh; rr_release 1.9.0
  rr_commit "feat: Add more" scripts/run.sh; rr_release 1.10.0
  rr_commit "fix: Repair" scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  [ "$(kv last)" = 1.10.0 ]
  [ "$(kv next)" = 1.10.1 ]
}

@test "an explicit version may skip versions (1.0.0 -> 1.5.0) and a new major needs no .0.0 check" {
  rr_commit "feat: Add" scripts/run.sh
  nv --version 1.5.0
  [ "$status" -eq 0 ]
  [ "$(kv next)" = 1.5.0 ]
  [ "$(kv level)" = minor ]
  nv --version 3.2.1
  [ "$status" -eq 0 ]
  [ "$(kv level)" = major ]
}

@test "the version syntax is X.Y.Z only; --version needs --bump auto; unknown values are refused" {
  rr_commit "fix: Repair" scripts/run.sh
  local v
  for v in 1.2 v1.2.3 1.2.3-rc1 1.2.3.4 abc "1.2.3 " " "; do
    nv --version "$v"
    [ "$status" -ne 0 ] || { echo "accepted '$v'"; return 1; }
  done
  nv --version "" --bump auto   # an empty version is "not given": the workflow input arrives empty in auto mode
  [ "$status" -eq 0 ]
  [ "$(kv next)" = 1.0.1 ]
  nv --version 1.5.0 --bump minor
  [ "$status" -ne 0 ]
  nv --bump major
  [ "$status" -ne 0 ]
  nv --nope
  [ "$status" -ne 0 ]
}

@test "tags that are not vX.Y.Z (the alias v1, a pre-release, a foreign tag) are ignored when looking for the last release" {
  rr_git tag v9 HEAD
  rr_git tag v9.9.9-dev.1 HEAD
  rr_git tag some-tag HEAD
  rr_commit "fix: Repair" scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  [ "$(kv last)" = 1.0.0 ]
}

@test "without any release tag the first release needs an explicit version; with one it is accepted" {
  rr_git tag -d v1.0.0 v1 >/dev/null
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"first release needs an explicit --version"* ]]
  nv --version 1.0.0
  [ "$status" -eq 0 ]
  [ "$(kv release)" = true ]
  [ "$(kv next)" = 1.0.0 ]
}

# --- RA4: an anomalous tag stops the calculation ---------------------------------------------------------------------------------

@test "RA4: a lightweight tag made by hand on a normal commit is refused" {
  rr_commit "feat: Add" scripts/run.sh
  rr_git tag v1.1.0 HEAD
  rr_commit "fix: Repair" scripts/run.sh
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"v1.1.0 is anomalous"* ]]
}

@test "RA4: a release tag whose commit has two parents is refused" {
  local a b c
  a=$(rr_git rev-parse HEAD)
  rr_commit "feat: Add" scripts/run.sh
  b=$(rr_git rev-parse HEAD)
  c=$(rr_git commit-tree -p "$a" -p "$b" -m "release: v1.1.0 (internal references pinned to $a)" "$b^{tree}")
  rr_git tag -a v1.1.0 -m v1.1.0 "$c"
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"exactly one parent (it has 2)"* ]]
}

@test "RA4: a release commit whose subject was altered is refused" {
  rr_commit "feat: Add" scripts/run.sh
  local src
  src=$(rr_git rev-parse HEAD)
  rr_git switch -q --detach "$src"
  rr_git commit -q --allow-empty -m "release: v1.1.0 (internal references pinned to ${src:0:12})"
  rr_git tag -a v1.1.0 -m v1.1.0
  rr_git switch -q main
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"v1.1.0 is anomalous"* && $stderr == *"canonical"* ]]
}

@test "RA4: a release commit that names a different parent in its subject is refused" {
  rr_commit "feat: Add" scripts/run.sh
  local src
  src=$(rr_git rev-parse HEAD)
  rr_git switch -q --detach "$src"
  rr_git commit -q --allow-empty -m "release: v1.1.0 (internal references pinned to $(rr_git rev-parse "$src~1"))"
  rr_git tag -a v1.1.0 -m v1.1.0
  rr_git switch -q main
  nv
  [ "$status" -ne 0 ]
}

@test "a history rewritten after the release (the base is not an ancestor of HEAD) is refused" {
  rr_commit "feat: Add" scripts/run.sh
  rr_release 1.1.0
  rr_git checkout -q --orphan rewritten
  rr_git commit -q -m "fix: Start over"
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"not an ancestor of HEAD"* ]]
}

# --- RA8: commit text is data, never code -----------------------------------------------------------------------------------------

@test "RA8: a hostile subject is never evaluated and workflow commands are neutralised in the report and in every stream" {
  rr_commit 'fix: evil $(touch pwned) `touch pwned2` "quoted" '"'"'single'"'"' ::error::boom ::add-mask::x' scripts/run.sh
  rr_commit '::warning::injected at the start of the line' scripts/run.sh
  RR_BODY=$'line\n::error::in the body $(touch pwned3)' rr_commit 'chore: body test' scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  no_file "$RR/pwned" "$RR/pwned2" "$RR/pwned3" "$BATS_TEST_TMPDIR/pwned"
  report_lacks '::error::'
  report_lacks '::warning::'
  report_lacks '::add-mask::'
  [[ $output != *"::"* && $stderr != *"::"* ]]
  report | grep -qF 'touch pwned'   # the text survives as data
}

@test "RA8: a hostile subject inside an error message is neutralised too" {
  rr_commit 'feat!: ::error::boom $(touch pwned)' scripts/run.sh
  nv
  [ "$status" -ne 0 ]
  no_file "$RR/pwned"
  [[ $stderr != *"::error::boom"* ]]
  report_lacks '::error::'
}

@test "RA8: control characters and markup in a subject do not reach the report raw" {
  rr_commit $'fix: <img src=x> a|b\ttab\x01ctl' scripts/run.sh
  nv
  [ "$status" -eq 0 ]
  report_lacks '<img'
  report_lacks $'\x01'
}

# --- RA12: a decision over nothing proves nothing ----------------------------------------------------------------------------------

@test "RA12: a tree with no contracts is an error, not a silent pass" {
  rr_git rm -q -r contracts
  rr_git commit -q -m "fix: Remove the contracts"
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"0 contracts discovered"* ]]
}

@test "RA12: a tree where every path is non-surface is an error, not a silent pass" {
  rr_git rm -q -r contracts .github scripts
  rr_git commit -q -m "fix: Leave only docs and tests"
  nv
  [ "$status" -ne 0 ]
  [[ $stderr == *"0 surface files discovered"* ]]
}

@test "--classify marks a new path as surface and a listed one as non-surface with its pattern; --print-non-surface lists the patterns" {
  run bash -c "printf 'scripts/brand-new.sh\0docs/x/y.md\0README.md\0notes.md\0sub/notes.md\0' | bash '$SCRIPTS/next-version.sh' --classify"
  [ "$status" -eq 0 ]
  [[ $output == *$'surface\tscripts/brand-new.sh'* ]]
  [[ $output == *$'non-surface\tdocs/x/y.md\tdocs/**'* ]]
  [[ $output == *$'non-surface\tREADME.md\t*.md'* ]]
  [[ $output == *$'non-surface\tnotes.md\t*.md'* ]]
  [[ $output == *$'surface\tsub/notes.md'* ]]   # '*.md' is the root only
  run bash "$SCRIPTS/next-version.sh" --print-non-surface
  [ "$status" -eq 0 ]
  [[ $output == *'docs/**'* && $output == *'scripts/lib/tools.env'* ]]
}

@test "the report is written on failure too, and not at all when NEXT_VERSION_REPORT is unset" {
  rr_edit_contract 'del(.inputs.flavor)' "feat: Remove an input"
  nv
  [ "$status" -ne 0 ]
  [ -s "$NEXT_VERSION_REPORT" ]
  rm -f "$NEXT_VERSION_REPORT"
  unset NEXT_VERSION_REPORT
  nv
  [ ! -e "$BATS_TEST_TMPDIR/report.md" ]
}
