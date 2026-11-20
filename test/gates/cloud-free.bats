#!/usr/bin/env bats
# Gates of the cloud-free family: the reusable workflows named lego-* that are not lego-aws-* (lego-node-ci, lego-package-release). They assume
# no role and mint no token; the one write permission of the family belongs to the `release` job of lego-package-release. Subjects are
# discovered on disk, a gate that finds none fails, and every gate is verified in red by test/bats/gates-red.bats.
#   CF-SEC    the only secret the family may declare is the optional INTERNAL_DENYLIST, in lego-node-ci and lego-package-release; nothing looks like a credential
#   CF-TOKEN  the token of the run is read only in the env: of a step of a composite that only the release job uses
#   CF-REL    the release job: no checkout, no caller code, only the artifact and the publish composite; the gate job: read-only, one pack
#   CF-NOREWRITE  the script of the release job never rewrites a published Release and never prints the token
#   CF-CALLER every sandbox caller of the family: pinned by tag, no id-token, the permissions the callee needs, the right triggers, no inherit

load 'lib/gates'

# The ONE secret of the family and the workflows that declare it (both run the tests of a caller, which may include the public-names gate of a
# public repository). Declared twice on purpose (SPEC corollary b): here, and in the contract and the workflow; an entry whose workflow stopped
# declaring it fails the gate as stale.
declare -gA CF_SECRETS=([lego-node-ci]=INTERNAL_DENYLIST [lego-package-release]=INTERNAL_DENYLIST)

# What the release job may `uses:`. An unknown step type must be a conscious change of this list, with its reason:
#   actions/download-artifact  brings the artifact of the gate (data, never executed)
#   package-release-publish    the composite that talks to the GitHub API with the token of the run
CF_RELEASE_USES=('actions/download-artifact@' '/.github/actions/package-release-publish@')

TOKEN_NAME_RE='token|secret|passw|credential|auth|key'
TOKEN_EXPR_RE='github\.token|secrets\.GITHUB_TOKEN'

# composites_of_job <json> <job>: names of the internal composites the job uses
composites_of_job() {
  jq -r --arg j "$2" '.jobs[$j].steps[]? | .uses // empty | capture("/\\.github/actions/(?<n>[a-z0-9-]+)@")? | .n' <<<"$1"
}

# code_lines <file>: the lines of a file that are not comments
code_lines() { grep -vE '^[[:space:]]*#' "$GATES_ROOT/$1" || true; }

@test "CF-SEC: the only secret of the cloud-free family is the optional INTERNAL_DENYLIST of lego-node-ci and lego-package-release; nothing else looks like a credential" {
  gate_require_tools yq jq
  gate_discover CF-SEC contracts -maxdepth 1 -type f -name 'lego-*.contract.yml' -not -name 'lego-aws-*.contract.yml'
  local contracts=("${GATE_SUBJECTS[@]}")
  gate_discover_cloudfree_workflows CF-SEC
  local workflows=("${GATE_SUBJECTS[@]}") f name key allowed declared used line
  GATE_VIOLATIONS=()

  for f in "${contracts[@]}" "${workflows[@]}"; do
    name="$(basename "$f")"
    name="${name%.contract.yml}"
    name="${name%.yml}"
    allowed="${CF_SECRETS[$name]:-}"
    if [[ $f == contracts/* ]]; then
      declared="$(gate_json "$f" | jq -r '(.secrets // {}) | keys[]')"
      while IFS= read -r key; do
        [[ -n $key ]] || continue
        gate_json "$f" | jq -e --arg k "$key" '.secrets[$k].required == false' >/dev/null ||
          gate_violation "$f" "secret '$key' must be declared with required: false (a caller without it must still be able to call)"
      done <<<"$declared"
      while IFS= read -r key; do
        gate_violation "$f" "input '$key' looks like a credential: the cloud-free family has no token input (CF-SEC)"
      done < <(gate_json "$f" | jq -r --arg re "$TOKEN_NAME_RE" '(.inputs // {}) | keys[] | select(test($re; "i"))')
    else
      declared="$(gate_json "$f" | jq -r '(.on.workflow_call.secrets // {}) | keys[]')"
      while IFS= read -r key; do
        [[ -n $key ]] || continue
        gate_json "$f" | jq -e --arg k "$key" '.on.workflow_call.secrets[$k].required != true' >/dev/null ||
          gate_violation "$f" "secret '$key' must not be required: a caller without it must still be able to call"
      done <<<"$declared"
      while IFS= read -r key; do
        gate_violation "$f" "input '$key' looks like a credential: the cloud-free family has no token input (CF-SEC)"
      done < <(gate_json "$f" | jq -r --arg re "$TOKEN_NAME_RE" '(.on.workflow_call.inputs // {}) | keys[] | select(test($re; "i"))')
      # the secrets context: only the allowed secret, only in the workflow that declares it, only as the value of an env: of the test step
      while IFS= read -r line; do
        gate_violation "$f" "line ${line%%:*} reads a secret other than the one this workflow may declare${allowed:+ ($allowed)} (CF-SEC)"
      done < <(code_lines "$f" | grep -nE '\$\{\{[^}]*secrets\.' | grep -vE "secrets\.${allowed:-__none__}([^A-Za-z0-9_]|\$)" || true)
      if [[ -n $allowed ]]; then
        used="$(gate_json "$f" | jq -r --arg k "$allowed" '[.jobs[]?.steps[]? | select(((.uses // "") | test("/\\.github/actions/node-ci@")) and (.with.command == "test")) | .env // {} | to_entries[] | select(.value == "${{ secrets." + $k + " }}")] | length')"
        [[ $used == 1 ]] ||
          gate_violation "$f" "secret '$allowed' must reach exactly one place: the env: of the node-ci test step (found $used)"
        [[ "$(code_lines "$f" | grep -cE "secrets\.${allowed}([^A-Za-z0-9_]|\$)" || true)" == 1 ]] ||
          gate_violation "$f" "secret '$allowed' is read in more than one place"
      fi
    fi
    while IFS= read -r key; do
      [[ -n $key ]] || continue
      [[ $key == "$allowed" ]] ||
        gate_violation "$f" "declares the secret '$key': the only secret a cloud-free workflow may declare is INTERNAL_DENYLIST, and only ${!CF_SECRETS[*]} (CF-SEC)"
    done <<<"$declared"
  done

  # an entry of the allowlist must still be declared by its contract AND its workflow (no stale entry), and both must exist
  for name in "${!CF_SECRETS[@]}"; do
    for f in "contracts/$name.contract.yml" ".github/workflows/$name.yml"; do
      if [[ ! -f $GATES_ROOT/$f ]]; then
        gate_violation "$f" "is in the CF-SEC allowlist of the gate but does not exist (stale entry)"
        continue
      fi
      gate_json "$f" | jq -e --arg k "${CF_SECRETS[$name]}" '((.secrets // .on.workflow_call.secrets // {}) | has($k))' >/dev/null ||
        gate_violation "$f" "is in the CF-SEC allowlist for the secret '${CF_SECRETS[$name]}' but no longer declares it (stale entry: remove it from the gate)"
    done
  done
  gate_finish CF-SEC
}

@test "CF-TOKEN: the token of the run is read only in the env: of a step of a composite that the release job alone uses" {
  gate_require_tools yq jq
  gate_discover_cloudfree_workflows CF-TOKEN
  local workflows=("${GATE_SUBJECTS[@]}") wf json job comp path n_raw n_env used_by_release=0 other
  GATE_VIOLATIONS=()
  declare -A release_composites=()
  for wf in "${workflows[@]}"; do
    json="$(gate_json "$wf")"
    # the workflow itself never mentions the token: a job that needs it gets it from a composite
    [[ "$(code_lines "$wf" | grep -cE "$TOKEN_EXPR_RE" || true)" == 0 ]] ||
      gate_violation "$wf" "mentions the token of the run (github.token / secrets.GITHUB_TOKEN): only the env: of a step of the release composite may read it"
    while IFS= read -r job; do
      while IFS= read -r comp; do
        path=".github/actions/$comp/action.yml"
        if [[ ! -f $GATES_ROOT/$path ]]; then
          gate_violation "$wf" "job '$job' uses the composite '$comp', which does not exist ($path)"
          continue
        fi
        n_raw="$(code_lines "$path" | grep -cE "$TOKEN_EXPR_RE" || true)"
        if [[ $job == release ]]; then
          release_composites[$path]=1
        else
          [[ $n_raw == 0 ]] || gate_violation "$path" "reads the token of the run but is used by job '$job' of $wf: only the release job may reach it"
        fi
      done < <(composites_of_job "$json" "$job")
    done < <(jq -r '.jobs | keys[]' <<<"$json")
  done
  for path in "${!release_composites[@]}"; do
    n_raw="$(code_lines "$path" | grep -cE "$TOKEN_EXPR_RE" || true)"
    n_env="$(gate_json "$path" | jq --arg re "$TOKEN_EXPR_RE" '[.. | objects | select(has("env")) | .env | objects | to_entries[] | select(.value | tostring | test($re))] | length')"
    [[ $n_raw == "$n_env" ]] ||
      gate_violation "$path" "the token of the run appears $n_raw time(s) but only $n_env time(s) as the value of an env: entry: it must never be an input, an argument or part of a script"
    ((n_env > 0)) && used_by_release=$((used_by_release + 1))
    # a composite of the release job is not reachable from another job of any cloud-free workflow
    for wf in "${workflows[@]}"; do
      json="$(gate_json "$wf")"
      while IFS= read -r job; do
        [[ $job == release ]] && continue
        while IFS= read -r other; do
          [[ ".github/actions/$other/action.yml" == "$path" ]] &&
            gate_violation "$wf" "job '$job' uses '$other', the composite that holds the token of the release job"
        done < <(composites_of_job "$json" "$job")
      done < <(jq -r '.jobs | keys[]' <<<"$json")
    done
  done
  ((used_by_release > 0)) || gate_violation ".github/actions" "no composite of a release job reads the token of the run (a gate that finds nothing proves nothing)"
  gate_finish CF-TOKEN
}

@test "CF-REL: the release job has no checkout and runs no caller code; the gate job is read-only and packs once; the digest travels apart from the artifact" {
  gate_require_tools yq jq
  gate_discover_cloudfree_workflows CF-REL
  local all=("${GATE_SUBJECTS[@]}") wf json job found=0 u ok seen packs id uploaded dl
  GATE_VIOLATIONS=()
  declare -A used_allowed=()
  for wf in "${all[@]}"; do
    json="$(gate_json "$wf")"
    # a release workflow is discovered by what it DOES: one of its jobs holds contents: write
    jq -e '[.jobs[] | select(.permissions.contents? == "write")] | length > 0' <<<"$json" >/dev/null || continue
    found=$((found + 1))
    jq -e '[.jobs | to_entries[] | select(.value.permissions.contents? == "write")] | length == 1' <<<"$json" >/dev/null ||
      gate_violation "$wf" "more than one job holds contents: write: the release is the only write step of the run"
    job="$(jq -r '[.jobs | to_entries[] | select(.value.permissions.contents? == "write") | .key] | first' <<<"$json")"
    [[ $job == release ]] || gate_violation "$wf" "the job that holds contents: write is '$job', expected 'release'"

    # --- the release job -------------------------------------------------------------------------------------------------
    jq -e '.jobs.release.steps | length > 0' <<<"$json" >/dev/null || { gate_violation "$wf" "job release has no steps"; continue; }
    jq -e '(.jobs.release.needs // []) == ["gate"]' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job release must need exactly the gate job (a failed gate means no release)"
    jq -e '(.jobs.release.if // "") == ""' <<<"$json" >/dev/null || gate_violation "$wf" "job release must not carry an if: it runs whenever the gate succeeded"
    jq -e '.jobs.release.concurrency | type == "object" and (.group | startswith("package-release-") and contains("github.ref_name")) and (."cancel-in-progress" == false)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job release needs a concurrency group per tag ('package-release-\${{ github.ref_name }}') with cancel-in-progress: false (got $(jq -c '.jobs.release.concurrency' <<<"$json"))"
    jq -e '[.jobs.release.steps[] | select(has("run"))] | length == 0' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job release has a 'run:' step: it runs no script of its own, the composite does the work"
    while IFS= read -r u; do
      ok=0
      for seen in "${CF_RELEASE_USES[@]}"; do
        if [[ $u == *"$seen"* ]]; then ok=1; used_allowed[$seen]=1; fi
      done
      ((ok)) || gate_violation "$wf" "job release uses '$u': it may only download the artifact and call the publish composite (it never checks out and runs no code of the caller's repository)"
    done < <(jq -r '.jobs.release.steps[] | .uses // "(a step without uses)"' <<<"$json")
    jq -e '[.jobs.release.steps[] | (.uses // "") | test("actions/checkout")] | any | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job release checks out the repository: it must run no code of the caller's repository"
    # the digest comes from the gate's OUTPUT, an independent channel from the artifact it checks
    jq -e '[.jobs.release.steps[] | select((.uses // "") | test("/actions/package-release-publish@")) | .with.sha256] | length > 0 and all(. == "${{ needs.gate.outputs.sha256 }}")' <<<"$json" >/dev/null ||
      gate_violation "$wf" "every publish step of job release must take sha256 from needs.gate.outputs.sha256 (a channel apart from the artifact)"
    jq -e '[.jobs.release.steps[] | select((.uses // "") | test("/actions/package-release-publish@")) | .with.command] | index("create") != null and index("verify") != null and (index("create") < index("verify"))' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job release must create the Release and then verify it, in that order"

    # --- the gate job ----------------------------------------------------------------------------------------------------
    jq -e '.jobs.gate.permissions == {"contents": "read"}' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job gate must hold exactly {contents: read} (got $(jq -c '.jobs.gate.permissions' <<<"$json"))"
    jq -e '[.jobs.gate.steps[] | select((.uses // "") | test("actions/checkout@")) | .with["persist-credentials"]] | length > 0 and all(. == false)' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job gate must check out with persist-credentials: false (the code under test must find no credential in .git)"
    packs="$(jq -r '[.jobs.gate.steps[] | select(((.uses // "") | test("/actions/package-release-check@")) and (.with.command == "pack"))] | length' <<<"$json")"
    [[ $packs == 1 ]] || gate_violation "$wf" "job gate must pack exactly once (found $packs 'pack' steps): the bytes released are the bytes reviewed"
    jq -e '[.jobs | to_entries[] | .value.steps[]? | (.run // "") | test("(npm|pnpm|yarn)[[:space:]]+pack")] | any | not' <<<"$json" >/dev/null ||
      gate_violation "$wf" "a run: step packs the package: only the pack step of the gate does, once"
    jq -e '[.jobs.gate.steps[] | select((.uses // "") | test("/actions/package-release-check@")) | .with.command] | index("check") != null and index("check") < index("pack")' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job gate must run the tag/version check before it packs"
    jq -e '([.jobs.gate.steps[] | (.uses // "")] | map(test("/actions/package-release-check@") ) | index(true)) as $c | ([.jobs.gate.steps[] | (.uses // "")] | map(test("/actions/setup-project@")) | index(true)) as $s | $c != null and $s != null and $c < $s' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job gate must check the tag against package.json before the project is installed"
    id="$(jq -r '[.jobs.gate.steps[] | select(((.uses // "") | test("/actions/package-release-check@")) and (.with.command == "pack")) | .id] | first // ""' <<<"$json")"
    jq -e --arg id "$id" '.jobs.gate.outputs.sha256 == "${{ steps." + $id + ".outputs.sha256 }}" and .jobs.gate.outputs.tarball == "${{ steps." + $id + ".outputs.tarball }}"' <<<"$json" >/dev/null ||
      gate_violation "$wf" "job gate must expose tarball and sha256 from the pack step (id '${id}')"
    uploaded="$(jq -r '[.jobs.gate.steps[] | select((.uses // "") | test("actions/upload-artifact@")) | .with.name] | first // ""' <<<"$json")"
    dl="$(jq -r '[.jobs.release.steps[] | select((.uses // "") | test("actions/download-artifact@")) | .with.name] | first // ""' <<<"$json")"
    [[ -n $uploaded && $uploaded == "$dl" ]] ||
      gate_violation "$wf" "the artifact the gate uploads ('$uploaded') is not the one the release job downloads ('$dl')"
  done
  ((found > 0)) || gate_fail "CF-REL: no cloud-free workflow has a job that holds contents: write (a gate that finds nothing proves nothing)"
  for seen in "${CF_RELEASE_USES[@]}"; do
    [[ -n ${used_allowed[$seen]:-} ]] || gate_violation "test/gates/cloud-free.bats" "the release allowlist names '$seen' but no release job uses it (stale entry)"
  done
  gate_finish CF-REL
}

@test "CF-NOREWRITE: the script of the release job refuses an existing Release, never rewrites one, and never prints the token" {
  gate_require_tools yq jq
  gate_discover_cloudfree_workflows CF-NOREWRITE
  local workflows=("${GATE_SUBJECTS[@]}") wf json comp path script n view create first_view first_create found=0
  GATE_VIOLATIONS=()
  declare -A scripts=()
  for wf in "${workflows[@]}"; do
    json="$(gate_json "$wf")"
    jq -e '.jobs.release != null' <<<"$json" >/dev/null || continue
    while IFS= read -r comp; do
      path=".github/actions/$comp/action.yml"
      [[ -f $GATES_ROOT/$path ]] || continue
      while IFS= read -r script; do scripts["scripts/$script"]=1; done < <(gate_json "$path" | jq -r '[.runs.steps[]? | .run // empty] | .[] | capture("\\$SCRIPTS/(?<s>[A-Za-z0-9._-]+\\.sh)"; "g") | .s')
    done < <(composites_of_job "$json" release)
  done
  for script in "${!scripts[@]}"; do
    found=$((found + 1))
    [[ -f $GATES_ROOT/$script ]] || { gate_violation "$script" "is called by a release composite but does not exist"; continue; }
    while IFS=: read -r n _; do
      gate_violation "$script" "line $n rewrites or removes a Release or its assets (--clobber, release edit/delete/upload): a published Release is never rewritten"
    done < <(code_lines "$script" | grep -nE -- '--clobber|gh[[:space:]]+release[[:space:]]+(edit|delete|upload)|gh[[:space:]]+api[[:space:]].*(-X|--method)[[:space:]]+(PATCH|PUT|DELETE)' || true)
    view="$(grep -nE '^[[:space:]]*if[[:space:]].*gh release view' "$GATES_ROOT/$script" | head -n1 | cut -d: -f1 || true)"
    create="$(grep -nE '^[[:space:]]*gh release create' "$GATES_ROOT/$script" | head -n1 | cut -d: -f1 || true)"
    if [[ -z $create ]]; then
      gate_violation "$script" "has no 'gh release create' (a gate that finds nothing proves nothing)"
    elif [[ -z $view || $view -gt $create ]]; then
      gate_violation "$script" "must test 'gh release view' BEFORE 'gh release create': an existing Release is refused, never overwritten"
    fi
    while IFS=: read -r n _; do
      gate_violation "$script" "line $n prints the environment or traces the shell (set -x, printenv, env): the token would reach the log"
    done < <(code_lines "$script" | grep -nE 'set[[:space:]]+-[a-z]*x|xtrace|printenv|^[[:space:]]*env[[:space:]]*(\||$)|declare[[:space:]]+-p|export[[:space:]]+-p' || true)
    # GH_TOKEN is only required, masked and handed to gh through the environment: never an argument, an echo or a file
    while IFS=: read -r n _; do
      gate_violation "$script" "line $n uses GH_TOKEN other than in require_env / mask: it may only reach gh through the environment"
    done < <(code_lines "$script" | grep -nE 'GH_TOKEN|GITHUB_TOKEN' | grep -vE 'require_env|mask "\$GH_TOKEN"|^[0-9]+:[[:space:]]*#' || true)
  done
  ((found > 0)) || gate_fail "CF-NOREWRITE: no script of a release job was found (a gate that finds nothing proves nothing)"
  gate_finish CF-NOREWRITE
}

@test "CF-CALLER: every sandbox caller of a cloud-free workflow pins it by tag, holds no id-token, grants what the callee needs, fires on the right events and passes no inherited secrets" {
  gate_require_tools yq jq
  gate_discover_cloudfree_workflows CF-CALLER
  local workflows=("${GATE_SUBJECTS[@]}") wf name f json job callee want got key covered=()
  gate_discover CF-CALLER test/sandbox/callers -maxdepth 1 -type f -name '*.yml'
  local callers=("${GATE_SUBJECTS[@]}")
  GATE_VIOLATIONS=()
  for wf in "${workflows[@]}"; do
    name="$(basename "$wf" .yml)"
    n=0
    for f in "${callers[@]}"; do
      grep -qE "uses:.*/$name\.yml@" "$GATES_ROOT/$f" || continue
      n=$((n + 1))
      json="$(gate_json "$f")"
      jq -e '[.. | objects | select(has("id-token"))] | length == 0' <<<"$json" >/dev/null ||
        gate_violation "$f" "a caller of $name grants id-token: the cloud-free family needs none"
      jq -e --arg n "$name" '[.jobs[] | select((.uses // "") | test("/" + $n + "\\.yml@")) | .uses] | all(test("@v[0-9]+(\\.[0-9]+\\.[0-9]+)?$"))' <<<"$json" >/dev/null ||
        gate_violation "$f" "the workflow $name must be pinned by tag (@v1 or @vX.Y.Z)"
      jq -e '(.on | type == "object") and (.on | has("pull_request_target") | not)' <<<"$json" >/dev/null ||
        gate_violation "$f" "a caller must not use pull_request_target (it would run the code of a pull request with the permissions of the base)"
      # what the callee needs: the union of the contents level of its jobs; the caller's job grants exactly that
      want="$(gate_json "$wf" | jq -c '{contents: ([.jobs[].permissions.contents // "none"] | if any(. == "write") then "write" else "read" end)}')"
      while IFS= read -r job; do
        got="$(jq -c --arg j "$job" '.jobs[$j].permissions // .permissions // {}' <<<"$json")"
        [[ $got == "$want" ]] ||
          gate_violation "$f" "job '$job' calls $name and must grant exactly $want, which is what the callee's jobs need (got $got)"
        jq -e --arg j "$job" '(.jobs[$j].secrets // {}) | (type != "string")' <<<"$json" >/dev/null ||
          gate_violation "$f" "job '$job' passes 'secrets: inherit': pass the secrets by name"
        while IFS= read -r key; do
          gate_json "$wf" | jq -e --arg k "$key" '(.on.workflow_call.secrets // {}) | has($k)' >/dev/null ||
            gate_violation "$f" "job '$job' passes the secret '$key', which $name does not declare"
        done < <(jq -r --arg j "$job" '(.jobs[$j].secrets // {}) | if type == "object" then keys[] else empty end' <<<"$json")
      done < <(jq -r --arg n "$name" '.jobs | to_entries[] | select((.value.uses // "") | test("/" + $n + "\\.yml@")) | .key' <<<"$json")
      case "$name" in
        lego-package-release)
          jq -e '(.on.push.tags | type == "array" and length > 0) and (.on.push.branches == null) and (.on | has("pull_request") | not) and (.on | has("workflow_dispatch") | not)' <<<"$json" >/dev/null ||
            gate_violation "$f" "a caller of $name must fire only on the push of version tags (on.push.tags): a branch, a pull request or a manual run is not a release"
          ;;
        lego-node-ci)
          jq -e '(.on | has("pull_request")) and (.on | has("push"))' <<<"$json" >/dev/null ||
            gate_violation "$f" "a caller of $name must fire on pull_request and on push: a CI that does not run on the pull request blocks nothing"
          ;;
      esac
    done
    ((n > 0)) || gate_violation "$wf" "no sandbox caller in test/sandbox/callers uses it (a workflow nobody exercised)"
  done
  gate_finish CF-CALLER
}
