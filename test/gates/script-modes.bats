#!/usr/bin/env bats
# EXEC — every script a composite runs is executable. The composites call `"$SCRIPTS/<name>.sh"` directly: a script committed as 100644
# fails at run time with "Permission denied", and a suite that copies the tree and runs `chmod +x` (a local habit on Windows, where the
# file system has no exec bit) never notices. Subjects are discovered on disk, from the `run:` of every composite; a gate that finds none fails.
# Inside a git work tree the mode that counts is the one in the index (what a runner checks out); elsewhere, the mode on disk.

load 'lib/gates'

@test "EXEC: every script that a composite runs through \$SCRIPTS is executable (index mode 100755 in a git work tree)" {
  gate_require_tools yq jq
  gate_discover EXEC .github/actions -type f -name action.yml
  local composites=("${GATE_SUBJECTS[@]}") c s mode found=0 in_git=0
  declare -A scripts=()
  if [[ "$(git -C "$GATES_ROOT" rev-parse --show-toplevel 2>/dev/null || true)" == "$(cd "$GATES_ROOT" && pwd -P)" ]]; then in_git=1; fi
  for c in "${composites[@]}"; do
    while IFS= read -r s; do scripts["scripts/$s"]="$c"; done < <(gate_json "$c" | jq -r '[.runs.steps[]? | .run // empty] | .[] | capture("\\$SCRIPTS/(?<s>[A-Za-z0-9._/-]+\\.sh)"; "g") | .s')
  done
  GATE_VIOLATIONS=()
  for s in "${!scripts[@]}"; do
    found=$((found + 1))
    if [[ ! -f $GATES_ROOT/$s ]]; then
      gate_violation "${scripts[$s]}" "runs $s, which does not exist"
    elif ((in_git)); then
      mode="$(git -C "$GATES_ROOT" ls-files -s -- "$s" | cut -d' ' -f1)"
      if [[ -z $mode ]]; then   # not added yet: the mode on disk is all there is
        [[ -x $GATES_ROOT/$s ]] || gate_violation "$s" "is run by ${scripts[$s]}, is not tracked yet and is not executable"
      else
        [[ $mode == 100755 ]] || gate_violation "$s" "is run by ${scripts[$s]} but its mode in git is '$mode', not 100755 (git update-index --chmod=+x $s)"
      fi
    else
      [[ -x $GATES_ROOT/$s ]] || gate_violation "$s" "is run by ${scripts[$s]} but is not executable"
    fi
  done
  ((found > 0)) || gate_fail "EXEC: no composite runs a script through \$SCRIPTS (a gate that finds nothing proves nothing)"
  gate_finish EXEC
}
