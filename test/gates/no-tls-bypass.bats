#!/usr/bin/env bats
# G9 — no TLS verification bypass anywhere in .github/, scripts/ or contracts/.

load 'lib/gates'

@test "G9: no NODE_TLS_REJECT_UNAUTHORIZED and no sslmode weaker than require" {
  gate_discover G9 .github scripts contracts -type f
  local f
  for f in "${GATE_SUBJECTS[@]}"; do
    grep -qE 'NODE_TLS_REJECT_UNAUTHORIZED' "$GATES_ROOT/$f" &&
      gate_violation "$f" "mentions NODE_TLS_REJECT_UNAUTHORIZED (disabling TLS verification is forbidden)"
    grep -qiE 'sslmode=(disable|no-verify|allow|prefer)' "$GATES_ROOT/$f" &&
      gate_violation "$f" "uses an sslmode weaker than require (disable, no-verify, allow, prefer)"
    grep -qE 'rejectUnauthorized[[:space:]]*[:=][[:space:]]*false' "$GATES_ROOT/$f" &&
      gate_violation "$f" "sets rejectUnauthorized to false"
  done
  gate_finish G9
}
