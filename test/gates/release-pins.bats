#!/usr/bin/env bats
# G11 — a release leaves no internal reference on a mutable ref (SPEC D3, P2 GH1/R1).
#   (a) composites (.github/actions/*/action.yml) contain NO internal `uses:` at all: the workflows pin them to the source
#       commit of the release, so a reference inside a composite would still be @main at the end of the chain;
#   (b) scripts/release.sh run over the tree produces an output where every internal reference is a 40-hex SHA.

load 'lib/gates'

INTERNAL_RE='Nextep-xyz/nextep-platform-workflows/\.github/(actions|workflows)/'

@test "G11: composites hold no internal references, and the release tree has every internal reference pinned" {
  gate_discover G11 .github/actions -type f -name 'action.yml'
  local f line
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r line; do
      gate_violation "$f" "composite references this repository ('$line'): a composite cannot be pinned at release time; move the call to the workflow"
    done < <(grep -nE "^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*${INTERNAL_RE}" "$GATES_ROOT/$f" || true)
  done

  local kept=("${GATE_VIOLATIONS[@]}")   # gate_discover resets the violations
  gate_discover_lego_workflows G11
  GATE_VIOLATIONS=("${kept[@]}")
  local out="$BATS_TEST_TMPDIR/release-out" fake=0123456789abcdef0123456789abcdef01234567 rc=0 msg
  msg="$("$GATES_ROOT/scripts/release.sh" "$fake" "$out" "$GATES_ROOT" 2>&1)" || rc=$?
  if ((rc != 0)); then
    while IFS= read -r line; do
      [[ $line == *"unpinned internal reference"* ]] && line="${line##*output: }"; gate_violation "${line%%:*}" "internal reference left on a mutable ref by release.sh"
    done <<<"$msg"
    ((${#GATE_VIOLATIONS[@]} > 0)) || gate_violation "scripts/release.sh" "failed: $msg"
  else
    # independent re-check (does not trust release.sh's own check): nothing in the output ends in @main
    while IFS= read -r line; do
      gate_violation "${line%%:*}" "release output still has an internal @main reference"
    done < <(cd "$out" && grep -rnE "${INTERNAL_RE}[A-Za-z0-9._/-]+@main" .github | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    grep -rqE "${INTERNAL_RE}[A-Za-z0-9._/-]+@${fake}" "$out/.github/workflows" ||
      gate_violation "scripts/release.sh" "the release output has no reference pinned to the source commit (rewrite did nothing)"
  fi
  gate_finish G11
}

# T10 — release naming compatible with the collector (SPEC telemetria-dora 6): the token's job_workflow_ref ends in
# `lego-*.yml@refs/tags/v<N>` or `...v<N>.<M>.<P>`; the collector rejects anything else (a branch, a sha, `v1.2`).
# release.yml is the only thing that creates tags, so it may only produce those two shapes.
COLLECTOR_REF_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/lego-[a-z0-9-]+\.yml@refs/tags/v[0-9]+(\.[0-9]+\.[0-9]+)?$'

@test "T10: the collector's job_workflow_ref pattern accepts v1 and v1.2.0 and rejects v1.2, a branch and a sha (the pattern itself is pinned)" {
  local base='example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@'
  local ok bad
  for ok in refs/tags/v1 refs/tags/v1.2.0 refs/tags/v12.34.56; do
    [[ "$base$ok" =~ $COLLECTOR_REF_RE ]] || { echo "rejected $ok"; return 1; }
  done
  for bad in refs/tags/v1.2 refs/heads/main 0123456789abcdef0123456789abcdef01234567 refs/tags/1.2.0 refs/tags/v1.2.0-rc1 refs/tags/v1.; do
    [[ ! "$base$bad" =~ $COLLECTOR_REF_RE ]] || { echo "accepted $bad"; return 1; }
  done
}

@test "T10: release.yml only creates tags of the shapes vX.Y.Z and vX, and only from a resolved X.Y.Z version" {
  gate_require_tools yq jq
  gate_discover T10 .github/workflows -maxdepth 1 -type f -name release.yml
  local f=${GATE_SUBJECTS[0]} line n=0 shapes=0 tok
  grep -qF '[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]' "$GATES_ROOT/$f" ||
    gate_violation "$f" "the version guard is not '^[0-9]+\.[0-9]+\.[0-9]+\$': a vX.Y (or a pre-release) tag would be refused by the collector"
  while IFS= read -r line; do
    n=$((n + 1))
    [[ $line =~ git[[:space:]]+(tag|push) ]] || continue
    [[ $line =~ git[[:space:]]+tag ]] && shapes=$((shapes + 1))
    # every version token of a tag/push command must be one of the two allowed shapes
    while IFS= read -r tok; do
      [[ $tok == 'v${VERSION}' || $tok == 'v${VERSION%%.*}' ]] ||
        gate_violation "$f" "line $n creates or pushes a tag of an unexpected shape ($tok): the collector only accepts vX.Y.Z and vX"
    done < <(grep -oE 'v\$\{VERSION[^}]*\}' <<<"$line" || true)
  done <"$GATES_ROOT/$f"
  ((shapes > 0)) || gate_violation "$f" "no 'git tag' command found (a gate that finds nothing proves nothing)"

  # Release automation: the version is no longer a raw input but the RESOLVED one (the `next` output of the plan). Every step that
  # creates a tag must (a) take VERSION from that output, never from an input, and (b) check it is X.Y.Z in the SAME step, BEFORE its
  # first `git tag` / `git push`: the guard has to sit next to the command it protects, not somewhere else in the file.
  local step run ver i guard_line first_cmd tagging=0
  local from_plan='^\$\{\{ steps\.[A-Za-z0-9_-]+\.outputs\.next \}\}$'
  while IFS= read -r step; do
    tagging=$((tagging + 1))
    run=$(jq -r '.run' <<<"$step")
    ver=$(jq -r '.env.VERSION // ""' <<<"$step")
    [[ $ver =~ $from_plan ]] ||
      gate_violation "$f" "the step that creates tags takes VERSION from '$ver': it must be the resolved version of the plan (\${{ steps.<id>.outputs.next }}), never a raw input"
    guard_line=0 first_cmd=0 i=0
    while IFS= read -r line; do
      i=$((i + 1))
      if ((guard_line == 0)) && [[ $line == *'[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'* ]]; then guard_line=$i; fi
      if ((first_cmd == 0)) && [[ $line =~ git[[:space:]]+(tag|push) ]]; then first_cmd=$i; fi
    done <<<"$run"
    ((guard_line > 0 && guard_line < first_cmd)) ||
      gate_violation "$f" "the step that creates tags does not check '[[ \$VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+\$ ]]' before its first 'git tag' / 'git push'"
  done < <(gate_json "$f" | jq -c '.jobs[]?.steps[]? | select((.run // "") | test("git\\s+tag"))')
  ((tagging > 0)) || gate_violation "$f" "no step that creates tags was found (a gate that finds nothing proves nothing)"
  gate_finish T10
}
