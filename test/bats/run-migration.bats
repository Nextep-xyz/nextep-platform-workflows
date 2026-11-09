#!/usr/bin/env bats
# run-migration.sh with a fake aws and a fake tunnel: G4 (secrets), G8 (tunnel and teardown), G9 (TLS), G25 (env).

load 'helpers'

PASSWORD='p@ss:w/rd?#'
ENCODED='p%40ss%3Aw%2Frd%3F%23'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  export TUNNEL_DIR="$BATS_TEST_TMPDIR/tunnel" HOSTS_FILE="$BATS_TEST_TMPDIR/hosts" SUDO_CMD=""
  printf '127.0.0.1 localhost\n' >"$HOSTS_FILE"
  export OUT="$BATS_TEST_TMPDIR/out" ORDER="$BATS_TEST_TMPDIR/order"
  : >"$ORDER"
  export FAKE_PORT=$((20000 + RANDOM % 20000))
  FAKE_PYTHON="$(python3 -c 'print(1)' >/dev/null 2>&1 && command -v python3 || command -v python)"
  export FAKE_PYTHON
  export FAKE_SECRET_JSON="{\"username\":\"admin\",\"password\":\"$PASSWORD\"}"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : >"$GITHUB_ENV"

  export MODE=environment-deploy AWS_REGION=us-east-2 BASTION_ID=i-0abc123 DB_ENDPOINT=db.example.internal
  export DB_PORT="$FAKE_PORT" DB_SECRET_ID=shop/dev/core/database-credentials DB_NAME=shop_db DB_SCHEMA=shop_schema
  export DB_SSL_MODE=verify-full CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"
  printf 'fake-ca\n' >"$CA_BUNDLE"
  export DB_URL_TEMPLATE='postgresql://{user}:{password}@{host}:{port}/{db}?schema={schema}&sslmode={sslmode}'
  export MIGRATION_PRE_COMMAND="" POST_MIGRATE_COMMAND="" MIGRATION_TIMEOUT_MINUTES=1
  export MIGRATION_COMMAND='echo migrate >>"$ORDER"'
  export MIGRATION_VERIFY_COMMAND='echo verify >>"$ORDER"'
  export PROJECT=shop APP_ENV=dev APP_STAGE=Dev STACK_SUFFIX=Dev
  export TUNNEL_TIMEOUT=20 TUNNEL_INTERVAL=1
}

teardown() { "$SCRIPTS/ssm-tunnel-down.sh" >/dev/null 2>&1 || true; }

@test "G4: the password with @ : / ? # reaches the command URL-encoded and the URL is well formed" {
  export MIGRATION_COMMAND='printf "%s" "$DATABASE_URL" >"$OUT"'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = "postgresql://admin:${ENCODED}@db.example.internal:${FAKE_PORT}/shop_db?schema=shop_schema&sslmode=verify-full" ]
}

@test "G4: raw and encoded passwords are masked BEFORE anything else is logged and never appear elsewhere in the output" {
  export MIGRATION_COMMAND='echo "connecting to $DATABASE_URL"'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  mapfile -t lines <<<"$output"
  first_mask=-1 first_other=-1
  for i in "${!lines[@]}"; do
    if [[ ${lines[i]} == "::add-mask::"* ]]; then
      ((first_mask >= 0)) || first_mask=$i
    else
      ((first_other >= 0)) || first_other=$i
      [[ ${lines[i]} != *"$PASSWORD"* ]] || { echo "raw password leaked: ${lines[i]}"; return 1; }
    fi
  done
  [[ "$output" == *"::add-mask::${PASSWORD}"* ]]
  [[ "$output" == *"::add-mask::${ENCODED}"* ]]
  [[ "$output" == *"::add-mask::admin"* ]]
  ((first_mask == 0))
}

@test "G4: nothing is written to GITHUB_ENV" {
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "G4: a secret without username/password fails and a secret that cannot be read fails" {
  export FAKE_SECRET_JSON='{"user":"x"}'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must contain the keys 'username' and 'password'"* ]]
  export FAKE_SECRET_FAIL=1
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read the database secret"* ]]
}

@test "G8: a dead tunnel fails with the tunnel log and the migration never runs" {
  export FAKE_TUNNEL=die
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TargetNotConnected"* ]]
  [ ! -s "$ORDER" ]
}

@test "G8: the teardown runs when the migration fails (process killed, hosts entry gone)" {
  export MIGRATION_COMMAND='exit 7'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stage 'migration' failed (exit 7)"* ]]
  [ ! -f "$TUNNEL_DIR/ssm-tunnel.pid" ]
  ! grep -q "ssm-tunnel" "$HOSTS_FILE"
}

@test "G8: a command that exceeds its timeout is reported as a timeout" {
  export FAKE_TIMEOUT_RC=124
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out after 1 minutes"* ]]
}

@test "environment-deploy: pre -> migrate -> verify -> post, in that order" {
  export MIGRATION_PRE_COMMAND='echo pre >>"$ORDER"' POST_MIGRATE_COMMAND='echo seed >>"$ORDER"'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$ORDER")" = "pre,migrate,verify,seed" ]
}

@test "environment-deploy: a verify that still fails after migrating fails the job in red and skips the seed" {
  export MIGRATION_VERIFY_COMMAND='exit 1' POST_MIGRATE_COMMAND='echo seed >>"$ORDER"'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"database is NOT aligned after migrating"* ]]
  ! grep -q seed "$ORDER"
}

@test "cicd: status 0 means no pending migrations: it does NOT migrate (the idempotent seed still runs)" {
  export MODE=cicd POST_MIGRATE_COMMAND='echo seed >>"$ORDER"' MIGRATION_VERIFY_COMMAND=true
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pending migrations, migration skipped"* ]]
  [ "$(paste -sd, "$ORDER")" = "seed" ]
}

@test "cicd: pending migrations -> pre, migrate, verify again (must pass), seed; one tunnel session" {
  export MODE=cicd MIGRATION_PRE_COMMAND='echo pre >>"$ORDER"' POST_MIGRATE_COMMAND='echo seed >>"$ORDER"'
  export MIGRATION_COMMAND='echo migrate >>"$ORDER"; touch "$BATS_TEST_TMPDIR/aligned"'
  export MIGRATION_VERIFY_COMMAND='[ -f "$BATS_TEST_TMPDIR/aligned" ]'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$ORDER")" = "pre,migrate,seed" ]
  [ "$(grep -c 'ssm start-session' "$FAKE_LOG")" -eq 1 ]
}

@test "cicd: still not aligned after migrating fails the job" {
  export MODE=cicd MIGRATION_VERIFY_COMMAND='exit 1'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT aligned"* ]]
}

@test "G25: the commands see the contract variables and DATABASE_URL, and none of the script's own control variables" {
  export MIGRATION_COMMAND='env >"$OUT"'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  local v
  for v in DATABASE_URL PROJECT APP_ENV APP_STAGE STACK_SUFFIX AWS_REGION; do grep -q "^${v}=" "$OUT"; done
  for v in DB_USER DB_PASSWORD DB_SECRET_ID DB_URL_TEMPLATE MODE BASTION_ID DB_ENDPOINT MIGRATION_COMMAND MIGRATION_VERIFY_COMMAND POST_MIGRATE_COMMAND CA_BUNDLE; do
    ! grep -q "^${v}=" "$OUT" || { echo "control variable $v leaked to the command"; return 1; }
  done
  # the raw password only exists inside DATABASE_URL (encoded), nowhere else
  ! grep -v '^FAKE_SECRET_JSON=' "$OUT" | grep -qF "$PASSWORD"
}

@test "G9: verify-full hands the CA bundle to the command (PGSSLROOTCERT, NODE_EXTRA_CA_CERTS); verify-full without a bundle is refused" {
  export MIGRATION_COMMAND='env >"$OUT"'
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 0 ]
  grep -qx "PGSSLROOTCERT=$CA_BUNDLE" "$OUT"
  grep -qx "NODE_EXTRA_CA_CERTS=$CA_BUNDLE" "$OUT"
  export CA_BUNDLE=""
  run "$SCRIPTS/run-migration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verify-full needs CA_BUNDLE"* ]]
}

@test "G9: any sslmode weaker than require is refused by the script itself" {
  local m
  for m in disable no-verify allow prefer; do
    export DB_SSL_MODE="$m"
    run "$SCRIPTS/run-migration.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"db-ssl-mode must be verify-full or require"* ]]
  done
}
