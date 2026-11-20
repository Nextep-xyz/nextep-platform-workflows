#!/usr/bin/env bats
# Flow invariants of the image family (lego-aws-image-*), discovered on disk (docs/specs/imagen-por-tag/SPEC.md section 3):
#   GI-F1 one job `publish`, no needs/if, serialized per repository of images without cancelling, no secrets and no telemetry;
#   GI-F2 the order validate -> aws-oidc -> ECR login -> build -> digest; nothing but the checkout runs before the validation, and no
#         step runs a command of the caller (its code enters only through the Dockerfile of the build, after the role, as in infra-deploy);
#   GI-F3 never `latest`: not in the workflow, the composite or the script, and the script forces ENVIRONMENT=release on the build;
#   GI-F4 the sandbox callers fire only on version tags, with exactly the permissions the role needs, the reusable pinned by an exact tag
#         and the role ARN from a repository variable.

load 'lib/gates'

# index of the first step of job $2 whose `uses` matches $3 and whose with.command is $4 ("" = any); -1 when absent
step_index() { # step_index <json> <job> <uses-regex> <command>
  jq -r --arg j "$2" --arg u "$3" --arg c "$4" '
    [.jobs[$j].steps[] | {u: (.uses // ""), c: (.with.command // "")}] as $s
    | ([range(0; $s | length) | select(($s[.].u | test($u)) and ($c == "" or $s[.].c == $c))] | first // -1)' <<<"$1"
}

@test "GI-F1: an image workflow has one job 'publish', no needs or if, a per-repository concurrency that never cancels, no secrets and no telemetry" {
  gate_require_tools yq jq
  gate_discover_image_workflows GI-F1
  local wf json
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '(.jobs | keys) == ["publish"]' <<<"$json" >/dev/null ||
      gate_violation "$wf" "must have exactly one job, 'publish' (got $(jq -c '.jobs | keys' <<<"$json"))"
    jq -e '(.jobs.publish.needs // null) == null and (.jobs.publish.if // "") == ""' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish must not carry needs: or if: it runs whenever the caller fires it"
    jq -e '.jobs.publish.concurrency | type == "object" and (.group | startswith("image-publish-")) and (."cancel-in-progress" == false)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish needs an 'image-publish-*' concurrency group with cancel-in-progress: false (got $(jq -c '.jobs.publish.concurrency' <<<"$json"))"
    jq -e '.jobs.publish.permissions == {"contents": "read", "id-token": "write"}' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish must hold exactly {contents: read, id-token: write} (got $(jq -c '.jobs.publish.permissions' <<<"$json"))"
    jq -e '((.on.workflow_call.secrets // {}) | length) == 0' <<<"$json" >/dev/null ||
      gate_violation "$wf" "declares workflow_call secrets: the role comes from OIDC and the ECR token is minted per run"
    jq -e '(.on.workflow_call.inputs // {}) | keys | map(select(test("telemetry|token|password|secret|key"; "i"))) | length == 0' <<<"$json" >/dev/null ||
      gate_violation "$wf" "has a telemetry, token, password, secret or key input: the image family carries no telemetry and no credential"
    jq -e '[.jobs.publish.steps[].uses // ""] | any(test("/actions/telemetry@")) | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish uses the telemetry composite: the image family sends none"
  done
  gate_finish GI-F1
}

@test "GI-F2: validate, aws-oidc, ECR login, build and digest run in that order, and nothing but the checkout runs before the validation" {
  gate_require_tools yq jq
  gate_discover_image_workflows GI-F2
  local wf json v o e b d i u
  for wf in "${GATE_SUBJECTS[@]}"; do
    json="$(gate_json "$wf")"
    v="$(step_index "$json" publish '/actions/image-publish@' validate)"
    o="$(step_index "$json" publish '/actions/aws-oidc@' '')"
    e="$(step_index "$json" publish '^aws-actions/amazon-ecr-login@' '')"
    b="$(step_index "$json" publish '/actions/image-publish@' build)"
    d="$(step_index "$json" publish '/actions/image-publish@' digest)"
    if ((v < 0 || o < 0 || e < 0 || b < 0 || d < 0)); then
      gate_violation "$wf" "job publish lacks a step (indexes: validate=$v oidc=$o ecr-login=$e build=$b digest=$d)"
      continue
    fi
    ((v < o && o < e && e < b && b < d)) ||
      gate_violation "$wf" "job publish must run: validate, aws-oidc, ECR login, build, digest (got $v, $o, $e, $b, $d)"
    # before the validation only the checkout may run (a step of the caller there would run with no check at all)
    for ((i = 0; i < v; i++)); do
      u="$(jq -r --argjson i "$i" '.jobs.publish.steps[$i].uses // ""' <<<"$json")"
      [[ $u == actions/checkout@* ]] || gate_violation "$wf" "step #$i runs before the validation and is not the checkout"
    done
    # this family takes no command from the caller: its code enters only through the Dockerfile
    jq -e '[.jobs.publish.steps[].uses // ""] | any(test("/actions/(run-project-command|setup-project|infra-deploy|deploy-ecs|deploy-lambda|migrate|ssm-tunnel|post-deploy)@")) | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish uses a composite that runs a command of the caller or deploys: this family builds an image and nothing else"
    jq -e '[.jobs.publish.steps[] | select(has("run"))] | length == 0' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job publish has an inline run: step; the logic lives in scripts/image-publish.sh behind the composite"
    jq -e '[.jobs.publish.steps[] | select((.uses // "") | test("/actions/image-publish@")) | .with["inputs-json"]] | all(. == "${{ toJSON(inputs) }}")' <<<"$json" >/dev/null ||
      gate_violation "$wf" "an image-publish step does not pass inputs-json: \${{ toJSON(inputs) }}"
  done
  gate_finish GI-F2
}

@test "GI-F3: 'latest' appears nowhere in the workflow, the composite or the script, and the script builds with ENVIRONMENT=release" {
  gate_require_tools yq jq
  gate_discover_image_workflows GI-F3
  local workflows=("${GATE_SUBJECTS[@]}") wf f line n script=scripts/image-publish.sh composite=.github/actions/image-publish/action.yml
  GATE_VIOLATIONS=()
  for f in "${workflows[@]}" "$composite" "$script"; do
    [[ -f $GATES_ROOT/$f ]] || { gate_violation "$f" "does not exist (an image workflow needs its composite and its script)"; continue; }
    n=0
    while IFS= read -r line || [[ -n $line ]]; do
      n=$((n + 1))
      [[ $line =~ ^[[:space:]]*# ]] && continue
      line="${line//ubuntu-latest/}"   # the runner label is not an image tag
      [[ $line =~ (^|[^A-Za-z0-9])latest([^A-Za-z0-9]|$) ]] && gate_violation "$f" "line $n mentions 'latest': a release image carries only its X.Y.Z tag"
    done <"$GATES_ROOT/$f"
  done
  if [[ -f $GATES_ROOT/$script ]]; then
    grep -qE '^[[:space:]]+ENVIRONMENT=release[[:space:]]*\\?$' "$GATES_ROOT/$script" ||
      gate_violation "$script" "does not build with ENVIRONMENT=release (build-push-image.sh adds latest when it is dev)"
  fi
  for wf in "${workflows[@]}"; do
    gate_json "$wf" | jq -e '(.on.workflow_call.inputs // {}) | has("environment") | not' >/dev/null ||
      gate_violation "$wf" "has an 'environment' input: it would reach the build and could turn latest back on"
  done
  gate_finish GI-F3
}

@test "GI-F4: sandbox callers of an image workflow fire only on version tags, with exact permissions, the reusable pinned by an exact tag and the role from vars" {
  gate_require_tools yq jq
  gate_discover_image_workflows GI-F4
  gate_discover GI-F4 test/sandbox/callers -maxdepth 1 -type f -name '*.yml'
  local callers=() f json
  for f in "${GATE_SUBJECTS[@]}"; do
    grep -q 'lego-aws-image-' "$GATES_ROOT/$f" && callers+=("$f")
  done
  ((${#callers[@]} > 0)) || gate_fail "GI-F4: no sandbox caller of an image workflow was found (a gate that finds nothing proves nothing)"
  GATE_VIOLATIONS=()
  for f in "${callers[@]}"; do
    json="$(gate_json "$f")"
    jq -e '(.on | type == "object") and (.on.push.tags | type == "array" and length > 0) and (.on.push.branches == null) and (.on | has("pull_request") | not) and (.on | has("workflow_dispatch") | not)' <<<"$json" >/dev/null ||
      gate_violation "$f" "a caller of an image workflow must fire only on the push of version tags (on.push.tags): a branch, a pull request or a manual run is not a release"
    jq -e '.permissions == {"id-token": "write", "contents": "read"}' <<<"$json" >/dev/null ||
      gate_violation "$f" "a caller of an image workflow must grant exactly {id-token: write, contents: read} (got $(jq -c '.permissions' <<<"$json"))"
    jq -e '[.jobs[].uses // ""] | all(test("@v[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$json" >/dev/null ||
      gate_violation "$f" "the reusable workflow must be pinned by an EXACT tag (@vX.Y.Z): the role's job_workflow_ref names that tag"
    jq -e '[.jobs[] | select((.uses // "") | test("lego-aws-image-")) | .with["role-arn"]] | all(. != null and test("^\\$\\{\\{ vars\\.[A-Z0-9_]+ \\}\\}$"))' <<<"$json" >/dev/null ||
      gate_violation "$f" "role-arn must come from a repository variable (\${{ vars.NAME }}), never a literal"
    jq -e '[.jobs[] | select((.uses // "") | test("lego-aws-image-")) | .secrets // null] | all(. == null)' <<<"$json" >/dev/null ||
      gate_violation "$f" "passes secrets to an image workflow, which takes none (and never secrets: inherit)"
  done
  gate_finish GI-F4
}
