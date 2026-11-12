#!/usr/bin/env bats
# T-DOC — the docs say what the code does, discovered on disk (SPEC telemetria-dora F4):
#   (a) every job that holds `id-token: write` in a reusable workflow is named in the id-token rule of AGENTS.md and in the G2 row of SPEC.md;
#   (b) the shared-secret design of the telemetry (TELEMETRY_TOKEN, HMAC, telemetry-enabled) only appears in text that declares it
#       superseded (on the same line or under a heading marked "SUSTITUIDO"): the docs must not promise what the workflows do not do;
#   (c) the section of SPEC.md that holds the old design points to the spec that replaces it.

load 'lib/gates'

@test "T-DOC (a): every job with id-token: write is named in the id-token rule of AGENTS.md and in the G2 row of SPEC.md" {
  gate_require_tools yq jq
  gate_discover_lego_workflows T-DOC
  local wf job jobs=() rule g2
  for wf in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r job; do jobs+=("$job"); done < <(gate_json "$wf" | jq -r '.jobs | to_entries[] | select(.value.permissions["id-token"]? == "write") | .key')
  done
  ((${#jobs[@]} > 0)) || gate_violation "AGENTS.md" "no job with id-token: write was discovered (a gate that finds nothing proves nothing)"
  rule="$(grep -E '`id-token: write` solo' "$GATES_ROOT/AGENTS.md" || true)"
  g2="$(grep -E '^\| G2 ' "$GATES_ROOT/SPEC.md" || true)"
  [[ -n $rule ]] || gate_violation "AGENTS.md" "the id-token rule (a line with '\`id-token: write\` solo') was not found"
  [[ -n $g2 ]] || gate_violation "SPEC.md" "the G2 row of the guards table was not found"
  for job in $(printf '%s\n' "${jobs[@]}" | sort -u); do
    [[ -z $rule || $rule == *"\`$job\`"* ]] || gate_violation "AGENTS.md" "the id-token rule does not name the job '$job', which holds id-token: write"
    [[ -z $g2 || $g2 == *"\`$job\`"* ]] || gate_violation "SPEC.md" "the G2 row does not name the job '$job', which holds id-token: write"
  done
  gate_finish T-DOC
}

@test "T-DOC (b): TELEMETRY_TOKEN, HMAC and telemetry-enabled only appear where the design is declared superseded" {
  gate_discover T-DOC . -maxdepth 2 -type f '(' -name README.md -o -name AGENTS.md -o -name SPEC.md -o -name runbook.md ')' -not -path './docs/specs/*'
  local f n line heading_ok
  for f in "${GATE_SUBJECTS[@]}"; do
    n=0 heading_ok=0
    while IFS= read -r line || [[ -n $line ]]; do
      n=$((n + 1))
      # only a level-2 heading decides: its sub-sections inherit it
      if [[ $line =~ ^##[[:space:]] ]]; then
        if [[ $line == *SUSTITUIDO* ]]; then heading_ok=1; else heading_ok=0; fi
      fi
      if [[ $line =~ TELEMETRY_TOKEN|[Hh][Mm][Aa][Cc]|telemetry-enabled ]] && ((heading_ok == 0)) && [[ $line != *[Ss]ustituid* && $line != *[Ss]uperseded* ]]; then
        gate_violation "$f" "line $n: mentions the superseded shared-secret telemetry design outside a section or line marked as superseded"
      fi
    done <"$GATES_ROOT/$f"
  done
  gate_finish T-DOC
}

@test "T-DOC (c): the old telemetry section of SPEC.md is marked superseded and points to the spec that replaces it" {
  gate_discover T-DOC . -maxdepth 1 -type f -name SPEC.md
  local f=SPEC.md
  grep -qE '^## 9\. .*SUSTITUIDO' "$GATES_ROOT/$f" || gate_violation "$f" "the heading of section 9 is not marked SUSTITUIDO"
  grep -q 'docs/specs/telemetria-dora/SPEC.md' "$GATES_ROOT/$f" || gate_violation "$f" "does not point to docs/specs/telemetria-dora/SPEC.md"
  [[ -f $GATES_ROOT/docs/specs/telemetria-dora/SPEC.md ]] || gate_violation "docs/specs/telemetria-dora/SPEC.md" "the spec that replaces section 9 does not exist"
  gate_finish T-DOC
}
