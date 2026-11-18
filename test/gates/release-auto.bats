#!/usr/bin/env bats
# Gates of the release automation (guards RA5, RA7, RA9, RA10 of the release-automation spec). Every gate discovers its subjects on
# disk, fails when it finds none, and is verified in red by test/bats/release-auto-red.bats.
#   RA5  dry_run has no effects: every step that runs the suite, builds the tree or changes git is gated by it;
#   RA7  the non-surface list lives twice (scripts/next-version.sh and docs/release-surface.yml) and neither rots;
#   RA9  the guard of a green CI reads the required jobs from self-ci.yml and runs before anything is released;
#   RA10 least privilege: contents: write + checks: read, RELEASE_TOKEN only for the checkout, the job token only in the CI guard.
# (RA2, the shape of the tags, is T10 in release-pins.bats.)

load 'lib/gates'

# Steps that must not run in a dry run: the suite, the release tree, and every git command that changes something.
MUTATING_RE='git[[:space:]]+(commit|tag|push)|release\.sh|(^|[^[:alnum:]_.-])bats[[:space:]]'

# release_workflows <gate>: the workflows that cut releases, discovered by what their steps DO (run release.sh or create tags).
release_workflows() {
  gate_discover "$1" .github/workflows -maxdepth 1 -type f '(' -name '*.yml' -o -name '*.yaml' ')'
  local all=("${GATE_SUBJECTS[@]}") f
  GATE_SUBJECTS=()
  for f in "${all[@]}"; do
    if gate_json "$f" | jq -e --arg re 'release\.sh|git\s+tag' '[.jobs[]?.steps[]? | select((.run // "") | test($re))] | length > 0' >/dev/null; then
      GATE_SUBJECTS+=("$f")
    fi
  done
  if ((${#GATE_SUBJECTS[@]} == 0)); then
    gate_fail "$1: 0 workflows that cut releases were discovered under .github/workflows (a gate that finds nothing proves nothing)"
    return 1
  fi
}

@test "RA5: every step of a release workflow that runs the suite, builds the tree or changes git is gated by 'inputs.dry_run != true' and by the plan" {
  gate_require_tools yq jq
  release_workflows RA5
  local f name n
  for f in "${GATE_SUBJECTS[@]}"; do
    gate_json "$f" | jq -e '.on.workflow_dispatch.inputs.dry_run | (.type == "boolean" and .default == false)' >/dev/null ||
      gate_violation "$f" "has no 'dry_run' input of type boolean with default false"
    n=0
    while IFS= read -r name; do
      gate_violation "$f" "step '$name' runs the suite, builds the release tree or changes git, but its 'if:' lacks 'inputs.dry_run != true' and \"release == 'true'\": a dry run would have effects"
    done < <(gate_json "$f" | jq -r --arg re "$MUTATING_RE" --arg c1 'inputs.dry_run != true' --arg c2 "release == 'true'" '
      .jobs[]?.steps[]? | select((.run // "") | test($re))
      | select(((.if // "") | tostring | (contains($c1) and contains($c2))) | not) | (.name // "(unnamed step)")')
    n=$(gate_json "$f" | jq --arg re "$MUTATING_RE" '[.jobs[]?.steps[]? | select((.run // "") | test($re))] | length')
    ((n > 0)) || gate_violation "$f" "no step that runs the suite, builds the tree or changes git was found (a gate that finds nothing proves nothing)"
  done
  gate_finish RA5
}

@test "RA7: the non-surface list lives twice (script and docs/release-surface.yml), with a reason, and no entry is stale" {
  gate_require_tools yq jq
  gate_discover RA7 docs -maxdepth 1 -type f -name release-surface.yml
  local yml=${GATE_SUBJECTS[0]} script=scripts/next-version.sh
  [[ -f $GATES_ROOT/$script ]] || { gate_fail "RA7: $script does not exist"; return 1; }

  local in_yml in_script p
  yq -e '.' "$GATES_ROOT/$yml" >/dev/null 2>&1 || { gate_violation "$yml" "is not valid YAML (quote any reason that contains ': ')"; gate_finish RA7; return; }
  in_yml=$(yq -r '.["non-surface"][]?.pattern' "$GATES_ROOT/$yml" | sort)
  in_script=$(bash "$GATES_ROOT/$script" --print-non-surface | sort)
  [[ -n $in_yml ]] || gate_violation "$yml" "has no 'non-surface' entries"
  [[ -n $in_script ]] || gate_violation "$script" "declares no NON_SURFACE patterns"
  while IFS= read -r p; do
    [[ -z $p ]] || grep -qxF -- "$p" <<<"$in_script" || gate_violation "$yml" "lists '$p' but $script does not: the two lists differ"
  done <<<"$in_yml"
  while IFS= read -r p; do
    [[ -z $p ]] || grep -qxF -- "$p" <<<"$in_yml" || gate_violation "$script" "lists '$p' but $yml does not: the two lists differ"
  done <<<"$in_script"
  while IFS= read -r p; do
    [[ -z $p ]] || gate_violation "$yml" "the entry '$p' has no reason"
  done < <(yq -r '.["non-surface"][]? | select((.reason // "") == "") | .pattern' "$GATES_ROOT/$yml")

  # classify every file on disk with the script itself (no second implementation of the matching here)
  local classified surface=0 matched
  classified=$(cd "$GATES_ROOT" && find . -type f -not -path './.git/*' -not -path '*/node_modules/*' -print0 | sed -z 's#^\./##' |
    bash "$GATES_ROOT/$script" --classify)
  while IFS=$'\t' read -r kind _ pat; do
    [[ $kind == surface ]] && surface=$((surface + 1))
  done <<<"$classified"
  ((surface > 0)) || gate_violation "$script" "0 surface files discovered on disk: every path is non-surface (a gate that finds nothing proves nothing)"
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    matched=$(awk -F'\t' -v p="$p" '$1 == "non-surface" && $3 == p { n++ } END { print n + 0 }' <<<"$classified")
    ((matched > 0)) || gate_violation "$yml" "the entry '$p' matches no versioned file: it is stale, delete it from both lists"
  done <<<"$in_yml"
  gate_finish RA7
}

@test "RA9: the CI guard exists, reads the required jobs from self-ci.yml, has none written by hand, and runs before anything is released" {
  gate_require_tools yq jq
  gate_discover RA9 .github/workflows -maxdepth 1 -type f -name self-ci.yml
  local ci=${GATE_SUBJECTS[0]} guard=scripts/ci/require-green-ci.sh
  local jobs=() j
  while IFS= read -r j; do jobs+=("$j"); done < <(yq -r '.jobs | to_entries[] | (.value.name // .key)' "$GATES_ROOT/$ci")
  ((${#jobs[@]} > 0)) || { gate_fail "RA9: $ci declares no jobs (a gate that finds nothing proves nothing)"; return 1; }
  release_workflows RA9   # discovery resets the violations: it goes before the first one is recorded
  local wfs=("${GATE_SUBJECTS[@]}")

  [[ -f $GATES_ROOT/$guard ]] || gate_violation "$guard" "does not exist: nothing checks that the CI is green before a release"
  if [[ -f $GATES_ROOT/$guard ]]; then
    grep -q 'self-ci.yml' "$GATES_ROOT/$guard" || gate_violation "$guard" "does not read the required jobs from self-ci.yml"
    grep -q 'yq' "$GATES_ROOT/$guard" || gate_violation "$guard" "does not read the job names with yq"
  fi

  local f guard_code step_code
  for f in "${wfs[@]}"; do
    gate_json "$f" | jq -e --arg c "release == 'true'" '[.jobs[]?.steps[]? | select((.run // "") | contains("require-green-ci.sh"))] | (length > 0 and all(.[]; ((.if // "") | tostring | contains($c))))' >/dev/null ||
      gate_violation "$f" "has no step that runs scripts/ci/require-green-ci.sh, or it is not gated by \"release == 'true'\""
    # order: the guard before the first step that runs the suite, builds the tree or changes git
    gate_json "$f" | jq -e --arg re "$MUTATING_RE" '
      [.jobs[]?.steps[]? | (.run // "")] as $runs
      | ([range(0; $runs | length) | select($runs[.] | contains("require-green-ci.sh"))] | first) as $g
      | ([range(0; $runs | length) | select($runs[.] | test($re))] | first) as $m
      | ($g != null and $m != null and $g < $m)' >/dev/null ||
      gate_violation "$f" "the CI guard does not run BEFORE the first step that runs the suite, builds the tree or changes git"
    # no job name written by hand in the guard step (env and run) of the workflow
    step_code=$(gate_json "$f" | jq -r '.jobs[]?.steps[]? | select((.run // "") | contains("require-green-ci.sh")) | ((.run // ""), (.env // {} | tostring))')
    for j in "${jobs[@]}"; do
      grep -qw -- "$j" <<<"$step_code" && gate_violation "$f" "the CI guard step names the job '$j' by hand: the required jobs must come from self-ci.yml"
    done
  done
  if [[ -f $GATES_ROOT/$guard ]]; then
    guard_code=$(grep -vE '^[[:space:]]*#' "$GATES_ROOT/$guard")
    for j in "${jobs[@]}"; do
      grep -qw -- "$j" <<<"$guard_code" && gate_violation "$guard" "names the job '$j' in code or in a message: the required jobs must be read from self-ci.yml, never written by hand"
    done
  fi
  gate_finish RA9
}

@test "RA10: a release workflow holds exactly contents: write + checks: read; RELEASE_TOKEN only feeds the checkout; the job token only feeds the CI guard" {
  gate_require_tools yq jq
  release_workflows RA10
  local f name
  for f in "${GATE_SUBJECTS[@]}"; do
    gate_json "$f" | jq -e '.permissions == null' >/dev/null || gate_violation "$f" "workflow-level 'permissions:' is forbidden; declare them per job"
    while IFS= read -r name; do
      gate_json "$f" | jq -e --arg j "$name" '.jobs[$j].permissions == {"contents": "write", "checks": "read"}' >/dev/null ||
        gate_violation "$f" "job '$name' cuts releases and must hold exactly {contents: write, checks: read} (got $(gate_json "$f" | jq -c --arg j "$name" '.jobs[$j].permissions'))"
    done < <(gate_json "$f" | jq -r '.jobs | to_entries[] | select([.value.steps[]? | select((.run // "") | test("release\\.sh|git\\s+tag"))] | length > 0) | .key')
    # RELEASE_TOKEN: only in the `token:` of actions/checkout
    while IFS= read -r name; do
      gate_violation "$f" "step '$name' uses RELEASE_TOKEN outside the token of actions/checkout: the push credential must not reach any other step"
    done < <(gate_json "$f" | jq -r '.jobs[]?.steps[]? | select(tostring | contains("RELEASE_TOKEN")) | select(((.uses // "") | startswith("actions/checkout@")) and ((.with.token // "") | contains("secrets.RELEASE_TOKEN")) and ((del(.with.token) | tostring | contains("RELEASE_TOKEN")) | not) | not) | (.name // .uses // "(unnamed step)")')
    # the job token: only in the step that runs the CI guard
    while IFS= read -r name; do
      gate_violation "$f" "step '$name' uses the job token (github.token / GITHUB_TOKEN) outside the CI guard: only the read-only guard may hold it"
    done < <(gate_json "$f" | jq -r '.jobs[]?.steps[]? | select(tostring | test("github\\.token|secrets\\.GITHUB_TOKEN")) | select((.run // "") | contains("require-green-ci.sh") | not) | (.name // .uses // "(unnamed step)")')
    gate_json "$f" | jq -e '[.jobs[]?.steps[]? | select(tostring | test("github\\.token|secrets\\.GITHUB_TOKEN"))] | length > 0' >/dev/null ||
      gate_violation "$f" "the CI guard has no job token: it cannot read the check-runs"
  done
  gate_finish RA10
}
