#!/usr/bin/env bats
# Flow invariants of the package family (lego-aws-package-*), discovered on disk:
#   GR12  the tag/version/scope check runs before anything else, in the gate AND in the publish job (the one with id-token);
#   GR-F1 the gate job holds no cloud credentials and publishes nothing;
#   GR-F2 inside publish, caller code (build) and the tarball scan run BEFORE the role is assumed, and the registry steps run
#         in the order token -> precheck -> publish -> verify;
#   GR-F3 the registry token goes from the token step to the publish composite and nowhere else; the publish step exists once;
#   GR-F4 concurrency per package without cancelling, and only the version tag as trigger in the sandbox callers.

load 'lib/gates'

# index of the first step of job $2 whose `uses` matches $3 and whose with.command is $4 ("" = any); -1 when absent
step_index() { # step_index <json> <job> <uses-regex> <command>
  jq -r --arg j "$2" --arg u "$3" --arg c "$4" '
    [.jobs[$j].steps[] | {u: (.uses // ""), c: (.with.command // "")}] as $s
    | ([range(0; $s | length) | select(($s[.].u | test($u)) and ($c == "" or $s[.].c == $c))] | first // -1)' <<<"$1"
}

@test "GR12: both jobs validate the inputs and check the manifest against the tag, in that order and before the project is set up" {
  gate_require_tools yq jq
  gate_discover_package_workflows GR12
  local wf json job v m s
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    for job in quality-and-security-gate publish; do
      v="$(step_index "$json" "$job" '/actions/package-check@' validate)"
      m="$(step_index "$json" "$job" '/actions/package-check@' check-manifest)"
      s="$(step_index "$json" "$job" '/actions/setup-project@' '')"
      if ((v < 0)); then gate_violation "$wf" "job '$job' does not validate the inputs and the tag trigger (package-check validate)"; continue; fi
      if ((m < 0)); then gate_violation "$wf" "job '$job' does not check the manifest against the tag (package-check check-manifest, GR12)"; continue; fi
      ((v < m)) || gate_violation "$wf" "job '$job': validate must run before check-manifest"
      ((s < 0 || m < s)) || gate_violation "$wf" "job '$job': check-manifest (GR12) must run before the project is set up, so a wrong tag fails before anything is installed"
    done
  done
  gate_finish GR12
}

@test "GR-F1: the gate job of a package workflow assumes no role, reads no registry and publishes nothing" {
  gate_require_tools yq jq
  gate_discover_package_workflows GR-F1
  local wf json
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.jobs | has("quality-and-security-gate")' <<<"$json" >/dev/null || { gate_violation "$wf" "has no quality-and-security-gate job"; continue; }
    jq -e '[.jobs["quality-and-security-gate"].steps[].uses // ""] | any(test("/actions/(aws-oidc|package-registry|package-publish)@")) | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job quality-and-security-gate uses aws-oidc, package-registry or package-publish: the gate holds no cloud credentials and publishes nothing"
    jq -e '(.jobs["quality-and-security-gate"].permissions["id-token"] // "none") == "none"' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job quality-and-security-gate holds id-token"
    jq -e '(.jobs.publish.needs // []) == ["quality-and-security-gate"]' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish must need exactly quality-and-security-gate (a failed gate means no publication)"
    jq -e '(.jobs.publish.if // "") == ""' <<<"$json" >/dev/null || gate_violation "$wf" "job publish must not carry an if: it runs whenever the gate succeeded"
  done
  gate_finish GR-F1
}

@test "GR-F2: in publish, the caller's build and the tarball scan run before the role is assumed, and the registry steps run in order" {
  gate_require_tools yq jq
  gate_discover_package_workflows GR-F2
  local wf json b sc o t p pub v
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    b="$(step_index "$json" publish '/actions/run-project-command@' '')"
    sc="$(step_index "$json" publish '/actions/package-check@' scan-tarball)"
    o="$(step_index "$json" publish '/actions/aws-oidc@' '')"
    t="$(step_index "$json" publish '/actions/package-registry@' token)"
    p="$(step_index "$json" publish '/actions/package-registry@' precheck)"
    pub="$(step_index "$json" publish '/actions/package-publish@' '')"
    v="$(step_index "$json" publish '/actions/package-registry@' verify)"
    if ((o < 0 || sc < 0 || t < 0 || p < 0 || pub < 0 || v < 0)); then
      gate_violation "$wf" "job publish lacks a step (indexes: oidc=$o scan=$sc token=$t precheck=$p publish=$pub verify=$v)"
      continue
    fi
    # every caller command step of publish (there may be several) must come before the role
    while IFS= read -r b; do
      ((b < o)) || gate_violation "$wf" "job publish runs a caller command (step #$b) after assuming the role: caller code must never see cloud credentials"
    done < <(jq -r '[.jobs.publish.steps | to_entries[] | select((.value.uses // "") | test("/actions/run-project-command@")) | .key] | .[]' <<<"$json")
    ((sc < o)) || gate_violation "$wf" "job publish must scan the tarball before assuming the role"
    ((o < t && t < p && p < pub && pub < v)) || gate_violation "$wf" "job publish must run: aws-oidc, token, precheck, publish, verify (got $o, $t, $p, $pub, $v)"
  done
  gate_finish GR-F2
}

@test "GR-F3: the token goes from the token step to the package-publish composite, which is used once, and to no other step" {
  gate_require_tools yq jq
  gate_discover_package_workflows GR-F3
  local wf json uses n id
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    n="$(jq -r '[.jobs[].steps[] | select((.uses // "") | test("/actions/package-publish@"))] | length' <<<"$json")"
    [[ $n == 1 ]] || gate_violation "$wf" "the package-publish composite must be used exactly once (found $n)"
    id="$(jq -r '[.jobs.publish.steps[] | select((.uses // "") | test("/actions/package-registry@")) | select(.with.command == "token") | .id] | first // ""' <<<"$json")"
    [[ -n $id ]] || { gate_violation "$wf" "the token step has no id: the publish step cannot receive its output"; continue; }
    jq -e --arg id "$id" '[.jobs.publish.steps[] | select((.uses // "") | test("/actions/package-publish@")) | .with["auth-token"]] == ["${{ steps." + $id + ".outputs.token }}"]' <<<"$json" >/dev/null ||
      gate_violation "$wf" "package-publish must take auth-token from steps.$id.outputs.token"
    # the token output is read nowhere else (not by a run, not by another composite, not as a job output)
    while IFS= read -r uses; do
      gate_violation "$wf" "the token output of step '$id' is also passed to '$uses'"
    done < <(jq -r --arg id "$id" '[.jobs[].steps[] | select((.uses // "") | test("/actions/package-publish@") | not) | select(((.with // {}) | tostring | contains("steps." + $id + ".outputs.token")) or ((.env // {}) | tostring | contains("steps." + $id + ".outputs.token"))) | .uses // .name] | .[]' <<<"$json")
    jq -e '[.jobs[] | (.outputs // {}) | tostring | contains("outputs.token")] | any | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "a job output carries the token (job outputs outlive the job)"
  done
  gate_finish GR-F3
}

@test "GR-F4: publish serializes per package without cancelling, and sandbox callers fire only on version tags with the permissions the role needs" {
  gate_require_tools yq jq
  gate_discover_package_workflows GR-F4
  local workflows=("${GATE_SUBJECTS[@]}") wf f json
  gate_discover GR-F4 test/sandbox/callers -maxdepth 1 -type f -name '*.yml'
  local callers=()
  for f in "${GATE_SUBJECTS[@]}"; do
    grep -q 'lego-aws-package-' "$GATES_ROOT/$f" && callers+=("$f")
  done
  ((${#callers[@]} > 0)) || gate_fail "GR-F4: no sandbox caller of a package workflow was found (a gate that finds nothing proves nothing)"
  GATE_VIOLATIONS=()
  for wf in "${workflows[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.jobs.publish.concurrency | type == "object" and (.group | startswith("package-publish-")) and (."cancel-in-progress" == false)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish needs a 'package-publish-*' concurrency group with cancel-in-progress: false (got $(jq -c '.jobs.publish.concurrency' <<<"$json"))"
  done
  for f in "${callers[@]}"; do
    json="$(gate_json "$f")"
    jq -e '(.on | type == "object") and (.on.push.tags | type == "array" and length > 0) and (.on.push.branches == null) and (.on | has("pull_request") | not) and (.on | has("workflow_dispatch") | not)' <<<"$json" >/dev/null ||
      gate_violation "$f" "a caller of a package workflow must fire only on the push of version tags (on.push.tags): a branch, a pull request or a manual run is not a release"
    jq -e '.permissions == {"id-token": "write", "contents": "read"}' <<<"$json" >/dev/null ||
      gate_violation "$f" "a caller of a package workflow must grant exactly {id-token: write, contents: read} (got $(jq -c '.permissions' <<<"$json"))"
    jq -e '[.jobs[].uses // ""] | all(test("@v[0-9]+(\\.[0-9]+\\.[0-9]+)?$"))' <<<"$json" >/dev/null ||
      gate_violation "$f" "the reusable workflow must be pinned by tag (@v1 or @vX.Y.Z): the role's job_workflow_ref names a tag"
  done
  gate_finish GR-F4
}
