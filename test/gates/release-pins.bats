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
