#!/usr/bin/env bats
# Gates of `root-kinds` (docs/runbook.md section 11.6): the caller declares the kind of each root and the packages evidence says what the kind
# requires against what the repository has. The policy is a file, the vocabulary is declared in more than one place, and the workflows must
# validate the input before using it, so the rules that keep those pieces together are tests, not prose. Subjects are discovered on disk (the
# profile file, the vocabulary library, every lego-*.yml that declares the input), a gate that finds none fails, and every gate is verified in
# red by test/bats/gates-red.bats.
#   RK-PROFILES  contracts/package-profiles.yml: every key is a kind of the vocabulary and every kind of the vocabulary has a key (the vocabulary
#                lives in scripts/lib/root-kinds.sh AND in the description of the input, and the three are crossed); every `required` is an
#                explicit list of @nextep/* names, without repeats
#   RK-VALIDATE  every workflow that declares `root-kinds` validates it BEFORE it is used (validate-inputs, flow cicd or node-ci), so a caller
#                written wrong fails the job instead of producing a report

load 'lib/gates'

PROFILES=contracts/package-profiles.yml
VOCAB_LIB=scripts/lib/root-kinds.sh
NAME_RE='^@nextep/[a-z0-9][a-z0-9._-]*$'

# vocab_of_lib: the kinds the validation accepts (the array ROOT_KINDS_VOCAB of the library), one per line
vocab_of_lib() {
  [[ -f $GATES_ROOT/$VOCAB_LIB ]] || return 0
  sed -nE 's/^ROOT_KINDS_VOCAB=\((.*)\)[[:space:]]*$/\1/p' "$GATES_ROOT/$VOCAB_LIB" | tr -s ' ' '\n' | sed '/^$/d' | sort -u
}

# vocab_of_description <workflow>: the kinds the input description promises to a caller ("Kinds (closed vocabulary): a, b, c.")
vocab_of_description() {
  gate_json "$1" | jq -r '.on.workflow_call.inputs["root-kinds"].description // ""' |
    sed -nE 's/.*Kinds \(closed vocabulary\): ([a-z, ]+)\..*/\1/p' | tr ',' '\n' | sed 's/[[:space:]]//g; /^$/d' | sort -u
}

# declaring_workflows: every lego-*.yml in GATE_SUBJECTS that declares the root-kinds input (found on disk, never listed)
declaring_workflows() {
  local wf
  for wf in "${GATE_SUBJECTS[@]}"; do
    if gate_json "$wf" | jq -e '(.on.workflow_call.inputs // {}) | has("root-kinds")' >/dev/null 2>&1; then printf '%s\n' "$wf"; fi
  done
  return 0
}

@test "RK-PROFILES: the profile file declares every kind of the vocabulary with an explicit list of @nextep/* names, and the vocabulary agrees in the library and in every input description" {
  gate_require_tools yq jq
  gate_discover RK-PROFILES contracts -maxdepth 1 -type f -name 'package-profiles.yml'
  local profile="${GATE_SUBJECTS[0]}" kind pkg dupes wf n=0 declaring=() vocab profile_keys
  gate_discover_lego_workflows RK-PROFILES
  while IFS= read -r wf; do [[ -n $wf ]] && declaring+=("$wf"); done < <(declaring_workflows)
  GATE_VIOLATIONS=()
  vocab="$(vocab_of_lib)"
  [[ -n $vocab ]] || gate_violation "$VOCAB_LIB" "declares no kind (or does not exist): expected a line ROOT_KINDS_VOCAB=(iac backend ...)"
  gate_json "$profile" | jq -e '(.kinds | type == "object") and (.kinds | length > 0)' >/dev/null ||
    gate_violation "$profile" "must declare 'kinds' as an object with at least one kind"
  profile_keys="$(gate_json "$profile" | jq -r '(.kinds // {}) | if type == "object" then keys[] else empty end' | sort -u)"
  # the two sets are equal: a kind accepted by the validation without a policy, and a policy of a kind nobody can declare, are both defects
  while IFS= read -r kind; do
    [[ -n $kind ]] || continue
    grep -qxF "$kind" <<<"$vocab" || gate_violation "$profile" "declares the kind '$kind', which is not in the vocabulary of $VOCAB_LIB (a kind nobody can declare)"
  done <<<"$profile_keys"
  while IFS= read -r kind; do
    [[ -n $kind ]] || continue
    grep -qxF "$kind" <<<"$profile_keys" || gate_violation "$profile" "has no entry for the kind '$kind' of the vocabulary: declare it, with 'required: []' if it requires nothing"
  done <<<"$vocab"
  # every kind says explicitly what it requires: a list, of valid package names, without repeats
  while IFS= read -r kind; do
    [[ -n $kind ]] || continue
    if ! gate_json "$profile" | jq -e --arg k "$kind" '.kinds[$k] | (type == "object") and (.required | type == "array") and (.required | all(type == "string"))' >/dev/null; then
      gate_violation "$profile" "kind '$kind' must declare 'required' as an explicit list of strings (use 'required: []' when it requires nothing)"
      continue
    fi
    while IFS= read -r pkg; do
      [[ -n $pkg ]] || continue
      [[ $pkg =~ $NAME_RE ]] || gate_violation "$profile" "kind '$kind': '$pkg' is not a @nextep/* package name (^@nextep/[a-z0-9][a-z0-9._-]*\$)"
    done < <(gate_json "$profile" | jq -r --arg k "$kind" '.kinds[$k].required[]')
    dupes="$(gate_json "$profile" | jq -r --arg k "$kind" '.kinds[$k].required | group_by(.)[] | select(length > 1) | .[0]')"
    [[ -z $dupes ]] || gate_violation "$profile" "kind '$kind' lists '${dupes//$'\n'/, }' more than once"
  done <<<"$profile_keys"
  # the description of the input a caller reads promises the same vocabulary, in every workflow that declares it
  for wf in "${declaring[@]}"; do
    n=$((n + 1))
    [[ "$(vocab_of_description "$wf")" == "$vocab" ]] ||
      gate_violation "$wf" "the description of input 'root-kinds' must say 'Kinds (closed vocabulary): $(tr '\n' ',' <<<"$vocab" | sed 's/,$//; s/,/, /g').' (the vocabulary of $VOCAB_LIB)"
  done
  ((n > 0)) || gate_violation ".github/workflows" "no workflow declares the input 'root-kinds' (a gate that finds nothing proves nothing)"
  gate_finish RK-PROFILES
}

@test "RK-VALIDATE: every workflow that declares root-kinds validates it (validate-inputs, flow cicd or node-ci) before the evidence step uses it" {
  gate_require_tools yq jq
  gate_discover_lego_workflows RK-VALIDATE
  local wf json job v_idx e_idx flow n=0 declaring=()
  while IFS= read -r wf; do [[ -n $wf ]] && declaring+=("$wf"); done < <(declaring_workflows)
  GATE_VIOLATIONS=()
  for wf in "${declaring[@]}"; do
    n=$((n + 1))
    json="$(gate_json "$wf")"
    while IFS= read -r job; do
      v_idx="$(jq -r --arg j "$job" '(.jobs[$j].steps // []) | map(.uses // "" | test("/\\.github/actions/validate-inputs@")) | index(true) // -1' <<<"$json")"
      e_idx="$(jq -r --arg j "$job" '(.jobs[$j].steps // []) | map(.uses // "" | test("/\\.github/actions/nextep-packages-evidence@")) | index(true) // -1' <<<"$json")"
      ((e_idx >= 0)) || continue
      if ((v_idx < 0)); then
        gate_violation "$wf" "job '$job' hands root-kinds to the packages evidence but never calls validate-inputs: a malformed value would only produce a report"
      elif ((v_idx > e_idx)); then
        gate_violation "$wf" "job '$job' validates the inputs AFTER the packages evidence has used root-kinds"
      else
        flow="$(jq -r --arg j "$job" --argjson i "$v_idx" '.jobs[$j].steps[$i].with.flow // ""' <<<"$json")"
        [[ $flow == cicd || $flow == node-ci ]] ||
          gate_violation "$wf" "job '$job': validate-inputs runs with flow '$flow'; a workflow that carries root-kinds must use flow cicd or node-ci, the ones that validate it"
        jq -e --arg j "$job" --argjson i "$v_idx" '.jobs[$j].steps[$i].with["inputs-json"] == "${{ toJSON(inputs) }}"' <<<"$json" >/dev/null ||
          gate_violation "$wf" "job '$job': validate-inputs must receive 'inputs-json: \${{ toJSON(inputs) }}' (root-kinds travels in it)"
      fi
    done < <(jq -r '.jobs | keys[]' <<<"$json")
  done
  ((n > 0)) || gate_violation ".github/workflows" "no workflow declares the input 'root-kinds' (a gate that finds nothing proves nothing)"
  gate_finish RK-VALIDATE
}
