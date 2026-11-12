#!/usr/bin/env bats
# T1 — the payload schema is the collector's schema (canonical hash), and the fixtures prove it is closed:
#   every valid fixture passes, every invalid one fails. Fixtures are discovered on disk.
# T4 (schema half) — one valid fixture per scenario (success, failure per stage, cancelled, rollback, static, ...);
#   a field the schema does not know (actor, lead_time_s, ...) must make the payload INVALID.

load 'lib/gates'

SCHEMA=contracts/telemetry.schema.json
HASH_FILE=contracts/telemetry.schema.sha256

# canonical_hash <schema>: sha256 of the schema without the two fields that name the origin ($id, description).
canonical_hash() { jq -cS 'del(."$id", .description)' "$GATES_ROOT/$1" | sha256sum | cut -d' ' -f1; }

@test "T1: the schema's canonical hash is the recorded one (a change must be made in the collector's repo and copied here)" {
  gate_require_tools jq sha256sum
  gate_discover T1 contracts -maxdepth 1 -type f -name 'telemetry.schema.json'
  [[ -f $GATES_ROOT/$HASH_FILE ]] || gate_violation "$HASH_FILE" "missing: record the canonical hash of $SCHEMA"
  if [[ -f $GATES_ROOT/$HASH_FILE ]]; then
    local want got
    want="$(tr -d '[:space:]' <"$GATES_ROOT/$HASH_FILE")"
    got="$(canonical_hash "$SCHEMA")"
    [[ $want == "$got" ]] || gate_violation "$SCHEMA" "canonical hash $got differs from the recorded $want: the schema was edited without syncing it with the collector"
  fi
  jq -e '.additionalProperties == false and (.properties | to_entries | map(select(.value.type == "object") | .value.additionalProperties == false) | all)' \
    "$GATES_ROOT/$SCHEMA" >/dev/null || gate_violation "$SCHEMA" "the schema is not closed (additionalProperties: false at every object level)"
  gate_finish T1
}

@test "T4: every valid payload fixture passes the schema" {
  gate_require_tools ajv
  gate_discover T4 test/fixtures/telemetry/valid -type f -name '*.json'
  local f out
  for f in "${GATE_SUBJECTS[@]}"; do
    out="$(ajv validate -s "$GATES_ROOT/$SCHEMA" -d "$GATES_ROOT/$f" --strict=false 2>&1)" ||
      gate_violation "$f" "valid fixture rejected by the schema: ${out//$'\n'/ }"
  done
  gate_finish T4
}

@test "T4: every invalid payload fixture is rejected by the schema (the whitelist is closed)" {
  gate_require_tools ajv
  gate_discover T4 test/fixtures/telemetry/invalid -type f -name '*.json'
  local f out rc
  for f in "${GATE_SUBJECTS[@]}"; do
    rc=0
    out="$(ajv validate -s "$GATES_ROOT/$SCHEMA" -d "$GATES_ROOT/$f" --strict=false 2>&1)" || rc=$?
    if ((rc == 0)); then
      gate_violation "$f" "invalid fixture ACCEPTED by the schema"
    elif [[ $out != *" invalid"* ]]; then
      # a tool error (missing schema, bad option) is not a rejection: it would make this gate pass on nothing
      gate_violation "$f" "could not be validated (tool error, not a schema rejection): ${out//$'\n'/ }"
    fi
  done
  gate_finish T4
}

@test "T4: the invalid fixtures cover the two removed fields (actor, lead_time_s)" {
  gate_discover T4 test/fixtures/telemetry/invalid -type f -name '*.json'
  local key f found
  for key in actor lead_time_s; do
    found=0
    for f in "${GATE_SUBJECTS[@]}"; do grep -q "\"$key\"" "$GATES_ROOT/$f" && found=1; done
    ((found)) || gate_violation "test/fixtures/telemetry/invalid" "no invalid fixture carries '$key'"
  done
  gate_finish T4
}
