#!/usr/bin/env bats
# G17 — the DORA block exists, is complete and is 100% commented in every lego-aws-*.yml (and in its contract).
# Markers: "# DORA-PLACEHOLDER:BEGIN" ... "# DORA-PLACEHOLDER:END". Activating it is a later, deliberate change.

load 'lib/gates'

# check_dora <file> <needle,...>: markers paired, every line in between commented, each needle present inside a block.
check_dora() {
  local f=$1 needles=$2 line in_block=0 blocks=0 n text="" lineno=0 begin_at=0 needle
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    if [[ $line =~ ^[[:space:]]*#[[:space:]]*DORA-PLACEHOLDER:BEGIN ]]; then
      ((in_block)) && gate_violation "$f" "line $lineno: DORA-PLACEHOLDER:BEGIN inside an open block (opened at line $begin_at)"
      in_block=1
      begin_at=$lineno
      blocks=$((blocks + 1))
    elif [[ $line =~ ^[[:space:]]*#[[:space:]]*DORA-PLACEHOLDER:END ]]; then
      ((in_block)) || gate_violation "$f" "line $lineno: DORA-PLACEHOLDER:END without BEGIN"
      in_block=0
    elif ((in_block)); then
      text+="$line"$'\n'
      [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] ||
        gate_violation "$f" "line $lineno: the DORA block must be 100% commented, found active code"
    fi
  done <"$GATES_ROOT/$f"
  ((in_block)) && gate_violation "$f" "DORA-PLACEHOLDER:BEGIN at line $begin_at is never closed"
  ((blocks > 0)) || gate_violation "$f" "no DORA-PLACEHOLDER:BEGIN/END block found"
  IFS=',' read -ra arr <<<"$needles"
  for needle in "${arr[@]}"; do
    [[ $text == *"$needle"* ]] || gate_violation "$f" "the DORA block is incomplete: '$needle' not found inside the markers"
  done
}

@test "G17: each reusable workflow carries a complete, fully commented DORA block and no active telemetry job/input" {
  gate_require_tools yq jq
  gate_discover_lego_workflows G17
  local wf
  for wf in "${GATE_SUBJECTS[@]}"; do
    check_dora "$wf" "telemetry-phone-home:,telemetry-url,TELEMETRY_TOKEN"
    gate_json "$wf" | jq -e '(.jobs | has("telemetry-phone-home")) | not' >/dev/null ||
      gate_violation "$wf" "the telemetry-phone-home job is ACTIVE; it must stay commented until the collector exists"
    gate_json "$wf" | jq -e '(.on.workflow_call.inputs // {}) | has("telemetry-url") | not' >/dev/null ||
      gate_violation "$wf" "the telemetry-url input is ACTIVE; it must stay commented"
    gate_json "$wf" | jq -e '(.on.workflow_call.secrets // {}) | has("TELEMETRY_TOKEN") | not' >/dev/null ||
      gate_violation "$wf" "the TELEMETRY_TOKEN secret is ACTIVE; it must stay commented"
  done
  gate_finish G17
}

@test "G17: each contract carries the commented DORA placeholders" {
  gate_require_tools yq jq
  gate_discover G17 contracts -maxdepth 1 -type f -name '*.contract.yml'
  local c
  for c in "${GATE_SUBJECTS[@]}"; do
    check_dora "$c" "telemetry-url,TELEMETRY_TOKEN,telemetry-phone-home"
  done
  gate_finish G17
}
