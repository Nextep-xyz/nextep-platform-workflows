#!/usr/bin/env bats
# G-PY4 — the Python toolchain reaches every job that sets the project up. Discovered from disk:
#   (a) every `setup-project` step of every reusable workflow passes python-version and python-requirements from the
#       workflow inputs (a job that forgets them would run lint, tests or the migration without Python);
#   (b) the composite declares both inputs and installs Python only when python-version is set;
#   (c) actions/setup-python is pinned by SHA with a version comment (G-PY5; the SHA itself is covered by G3).

load 'lib/gates'

@test "G-PY4: every setup-project step passes python-version and python-requirements from the workflow inputs" {
  gate_require_tools yq jq
  gate_discover_deploy_workflows G-PY4
  local wf json found=0 declared job step version reqs
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    while IFS=$'\t' read -r job step version reqs; do
      found=$((found + 1))
      [[ $version == '${{ inputs.python-version }}' ]] ||
        gate_violation "$wf" "job '$job', step '$step': python-version is not passed from the workflow input (got '${version:-<missing>}')"
      [[ $reqs == '${{ inputs.python-requirements }}' ]] ||
        gate_violation "$wf" "job '$job', step '$step': python-requirements is not passed from the workflow input (got '${reqs:-<missing>}')"
    done < <(jq -r '.jobs | to_entries[] | .key as $j | (.value.steps // [])[] | select((.uses // "") | test("/actions/setup-project@")) | [$j, (.name // "?"), (.with["python-version"] // ""), (.with["python-requirements"] // "")] | @tsv' <<<"$json")
    declared="$(jq -r '.on.workflow_call.inputs | [has("python-version"), has("python-requirements")] | all' <<<"$json")"
    [[ $declared == true ]] || gate_violation "$wf" "the workflow does not declare the inputs python-version and python-requirements"
  done
  ((found > 0)) || gate_fail "G-PY4: no setup-project step found in any reusable workflow (a gate that finds nothing proves nothing)"
  gate_finish G-PY4
}

@test "G-PY4: the setup-project composite declares the Python inputs and sets Python up only when a version is given" {
  gate_require_tools yq jq
  gate_discover G-PY4 .github/actions -type f -path '*/setup-project/action.yml'
  local f json n
  for f in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$f")"
    [[ "$(jq -r '.inputs | [has("python-version"), has("python-requirements")] | all' <<<"$json")" == true ]] ||
      gate_violation "$f" "the composite does not declare python-version and python-requirements"
    n="$(jq -r '[.runs.steps[] | select((.uses // "") | test("^actions/setup-python@"))] | length' <<<"$json")"
    [[ $n == 1 ]] || gate_violation "$f" "expected exactly one actions/setup-python step, found $n"
    jq -e '.runs.steps[] | select((.uses // "") | test("^actions/setup-python@")) | (.if // "") | contains("inputs.python-version != \"\"") or contains("inputs.python-version != '"''"'")' <<<"$json" >/dev/null ||
      gate_violation "$f" "the actions/setup-python step is not conditional on inputs.python-version != ''"
    jq -e '.runs.steps[] | select((.run // "") | test("python-install\\.sh")) | (.if // "") | contains("inputs.python-version != \"\"") or contains("inputs.python-version != '"''"'")' <<<"$json" >/dev/null ||
      gate_violation "$f" "the python-install.sh step is not conditional on inputs.python-version != ''"
  done
  gate_finish G-PY4
}

@test "G-PY5: every actions/setup-python reference is pinned by SHA and carries a version comment" {
  gate_discover G-PY5 .github -type f '(' -name '*.yml' -o -name '*.yaml' ')'
  local f found=0 line
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r line; do
      found=$((found + 1))
      [[ $line =~ uses:[[:space:]]+actions/setup-python@[0-9a-f]{40}[[:space:]]+#[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+ ]] ||
        gate_violation "$f" "actions/setup-python must be 'actions/setup-python@<40-hex SHA> # vX.Y.Z' (got: ${line#"${line%%[![:space:]]*}"})"
    done < <(grep -E 'uses:[[:space:]]+actions/setup-python@' "$GATES_ROOT/$f" || true)
  done
  ((found > 0)) || gate_fail "G-PY5: no actions/setup-python reference found under .github (a gate that finds nothing proves nothing)"
  gate_finish G-PY5
}
