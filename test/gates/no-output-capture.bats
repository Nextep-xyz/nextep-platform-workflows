#!/usr/bin/env bats
# G27 — a script captured with $(...) by a composite or a workflow must not write to GITHUB_OUTPUT.
# Inside a step GITHUB_OUTPUT is always set, so such a script sends its result to the file and the capture gets
# nothing. The unit tests run without GITHUB_OUTPUT and cannot see it: v1.0.0 shipped with this bug.

load 'lib/gates'

@test "G27: no script captured with \$(...) writes to GITHUB_OUTPUT" {
  gate_discover G27 .github -type f -name '*.yml'
  local f script path sites=0 re
  # $("$SCRIPTS/x.sh" ...)  /  $("${SCRIPTS}/x.sh" ...)  /  $($SCRIPTS/x.sh ...)
  re='\$\("?\$\{?[A-Z_]*SCRIPTS\}?"?/([a-z0-9-]+\.sh)'
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r script; do
      [[ -n $script ]] || continue
      sites=$((sites + 1))
      path="scripts/$script"
      if [[ ! -f $GATES_ROOT/$path ]]; then
        gate_violation "$f" "captures \$(\$SCRIPTS/$script) but $path does not exist"
      elif sed -E 's/(^|[[:space:]])#.*$//' "$GATES_ROOT/$path" | grep -q 'GITHUB_OUTPUT'; then # comments may mention it
        gate_violation "$f" "captures \$(\$SCRIPTS/$script) with \$(...), but $path writes to GITHUB_OUTPUT: inside a step the capture gets nothing"
      fi
    done < <(grep -oE "$re" "$GATES_ROOT/$f" | sed -E 's|.*/([a-z0-9-]+\.sh)$|\1|')
  done
  if ((sites == 0)); then
    gate_fail "G27: 0 capture sites discovered under .github (a gate that finds nothing proves nothing)"
    return 1
  fi
  gate_finish G27
}
