#!/usr/bin/env bats
# The mode of the packages policy: ONE function turns an environment into enforce | warn (scripts/lib/enforcement.sh), and run-command.sh hands
# its answer to every command of the caller as NEXTEP_GUARDRAILS_MODE (docs/runbook.md section 12).
#   E3  fail-closed: an empty or unknown environment is enforce, never warn      E4 (unit part)  run-command.sh passes the mode from APP_ENV
#   The gates that keep the function the only decision (EN-SINGLE, EN-ENV) are in test/gates/enforcement.bats.

load 'helpers'

setup() {
  # shellcheck source=../../scripts/lib/enforcement.sh
  source "$SCRIPTS/lib/enforcement.sh"
  unset NEXTEP_GUARDRAILS_MODE APP_ENV CMD
  OUT="$BATS_TEST_TMPDIR/seen"
}

@test "E3: dev and stg enforce, prod warns" {
  [ "$(enforcement_mode dev)" = enforce ]
  [ "$(enforcement_mode stg)" = enforce ]
  [ "$(enforcement_mode prod)" = warn ]
}

@test "E3: fail-closed: an empty, missing, unknown or mistyped environment is enforce (only the exact word prod relaxes)" {
  local e
  [ "$(enforcement_mode)" = enforce ]
  for e in "" " " "Prod" "PROD" "production" "prod " " prod" "prod2" "pro" "dev2" "qa" "preprod" "prod,dev" "prod;" "*" "\$prod"; do
    [ "$(enforcement_mode "$e")" = enforce ] || { echo "environment '$e' gave $(enforcement_mode "$e")"; return 1; }
  done
}

@test "the function prints one word and nothing else (no newline, no noise): a caller can compare it as a string" {
  [ "$(enforcement_mode prod | wc -c)" -eq 4 ]
  [ "$(enforcement_mode dev | wc -c)" -eq 7 ]
}

# --- run-command.sh: the mode reaches every command of the caller ---------------------------------------------------------------------------
seen_mode() { # seen_mode <APP_ENV or '-' for unset>: the NEXTEP_GUARDRAILS_MODE the command sees
  if [[ $1 == - ]]; then
    CMD='printf "%s" "${NEXTEP_GUARDRAILS_MODE-<unset>}" >"$OUT"' OUT="$OUT" run "$SCRIPTS/run-command.sh" lint
  else
    CMD='printf "%s" "${NEXTEP_GUARDRAILS_MODE-<unset>}" >"$OUT"' OUT="$OUT" APP_ENV="$1" run "$SCRIPTS/run-command.sh" lint
  fi
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cat "$OUT"
}

@test "run-command: the command sees enforce in dev and stg and warn in prod" {
  [ "$(seen_mode dev)" = enforce ]
  [ "$(seen_mode stg)" = enforce ]
  [ "$(seen_mode prod)" = warn ]
}

@test "run-command: an unset, empty or unknown APP_ENV is enforce (fail-closed)" {
  [ "$(seen_mode -)" = enforce ]
  [ "$(seen_mode '')" = enforce ]
  [ "$(seen_mode Prod)" = enforce ]
  [ "$(seen_mode production)" = enforce ]
}

@test "run-command: what the environment already had never decides: a caller (or a Makefile above it) cannot pre-set warn" {
  [ "$(NEXTEP_GUARDRAILS_MODE=warn seen_mode dev)" = enforce ]
  [ "$(NEXTEP_GUARDRAILS_MODE=warn seen_mode stg)" = enforce ]
  [ "$(NEXTEP_GUARDRAILS_MODE=enforce seen_mode prod)" = warn ]
  [ "$(NEXTEP_GUARDRAILS_MODE=garbage seen_mode -)" = enforce ]
}

@test "run-command: an empty command is still skipped (no mode, no group, exit 0) and a failing one still fails naming its label" {
  CMD="" APP_ENV=prod run "$SCRIPTS/run-command.sh" lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped 'lint': no command configured"* ]]
  CMD="exit 3" APP_ENV=prod run "$SCRIPTS/run-command.sh" lint
  [ "$status" -ne 0 ]
  [[ "$output" == *"'lint' failed (exit 3)"* ]]
}
