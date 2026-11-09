#!/usr/bin/env bats
# G4 (wiring) — nothing writes to $GITHUB_ENV (credentials would be visible to every later step).
# G25 (wiring) — DATABASE_URL only appears inside the migrate composite; the behavioural half of G25
# (the commands see the contract variables and nothing else) is test/bats/run-migration.bats.

load 'lib/gates'

@test "G4: no workflow, composite or script writes to GITHUB_ENV" {
  gate_discover G4 .github scripts -type f
  local f
  for f in "${GATE_SUBJECTS[@]}"; do
    grep -qE 'GITHUB_ENV' "$GATES_ROOT/$f" && gate_violation "$f" "references GITHUB_ENV (credentials and URLs must live only in the env: of the step that uses them)"
  done
  gate_finish G4
}

@test "G25: DATABASE_URL is referenced only by the migrate composite under .github/" {
  gate_discover G25 .github -type f
  local f
  for f in "${GATE_SUBJECTS[@]}"; do
    [[ $f == .github/actions/migrate/* ]] && continue
    grep -qE '(^|[^A-Za-z_])DATABASE_URL' "$GATES_ROOT/$f" && gate_violation "$f" "references DATABASE_URL outside the migrate composite"
  done
  gate_finish G25
}
