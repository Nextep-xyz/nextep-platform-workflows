#!/usr/bin/env bats
# bastion-ready.sh, wait-for-port.sh, ssm-tunnel-up/down.sh, install-ssm-plugin.sh — with a fake aws/curl.

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  export TUNNEL_DIR="$BATS_TEST_TMPDIR/tunnel"
  export HOSTS_FILE="$BATS_TEST_TMPDIR/hosts"
  printf '127.0.0.1 localhost\n' >"$HOSTS_FILE"
  export SUDO_CMD=""
  export AWS_REGION=us-east-2
  export FAKE_PORT=$((20000 + RANDOM % 20000))
  FAKE_PYTHON="$(python3 -c 'print(1)' >/dev/null 2>&1 && command -v python3 || command -v python)"
  export FAKE_PYTHON
}

teardown() { "$SCRIPTS/ssm-tunnel-down.sh" >/dev/null 2>&1 || true; }

# ---- bastion-ready ---------------------------------------------------------------------------------------------------

@test "bastion-ready: an Online bastion yields its id and the database endpoint" {
  export BASTION_ID_PARAM=/shop/core/Dev/bastion-id DB_ENDPOINT_PARAM=/shop/core/Dev/db-endpoint
  run "$SCRIPTS/bastion-ready.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bastion-id=i-0abc123"* ]]
  [[ "$output" == *"db-endpoint=db.example.internal"* ]]
}

@test "bastion-ready: a bastion that is off says so (no timeout, no endpoint lookup)" {
  export BASTION_ID_PARAM=/shop/core/Dev/bastion-id DB_ENDPOINT_PARAM=/shop/core/Dev/db-endpoint FAKE_PING=None
  run "$SCRIPTS/bastion-ready.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"switched off or outside its window"* ]]
  ! grep -q "db-endpoint" "$FAKE_LOG"
}

@test "bastion-ready: ConnectionLost is not Online either" {
  export BASTION_ID_PARAM=/shop/core/Dev/bastion-id DB_ENDPOINT_PARAM=/shop/core/Dev/db-endpoint FAKE_PING=ConnectionLost
  run "$SCRIPTS/bastion-ready.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PingStatus='ConnectionLost'"* ]]
}

# ---- wait-for-port -----------------------------------------------------------------------------------------------------

@test "wait-for-port: a dead tunnel process fails immediately and prints the tunnel log" {
  printf 'TargetNotConnected: boom\n' >"$BATS_TEST_TMPDIR/t.log"
  start=$SECONDS
  run "$SCRIPTS/wait-for-port.sh" --port "$FAKE_PORT" --pid 999999 --log "$BATS_TEST_TMPDIR/t.log" --timeout 30 --interval 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"died before"* ]]
  [[ "$output" == *"TargetNotConnected: boom"* ]]
  ((SECONDS - start < 10))
}

@test "wait-for-port: a port that never opens times out with the log, it does not wait forever" {
  printf 'still connecting\n' >"$BATS_TEST_TMPDIR/t.log"
  run "$SCRIPTS/wait-for-port.sh" --port "$FAKE_PORT" --log "$BATS_TEST_TMPDIR/t.log" --timeout 2 --interval 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout"* ]]
  [[ "$output" == *"still connecting"* ]]
}

@test "wait-for-port: succeeds as soon as the port accepts connections" {
  "$FAKE_PYTHON" -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(20)' "$FAKE_PORT" &
  listener=$!
  run "$SCRIPTS/wait-for-port.sh" --port "$FAKE_PORT" --timeout 15 --interval 1
  kill "$listener" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepting connections"* ]]
}

# ---- tunnel up / down --------------------------------------------------------------------------------------------------

@test "tunnel-up/down: up records pid, log and the hosts entry; down kills the process and removes the entry; down is idempotent" {
  export BASTION_ID=i-0abc123 DB_ENDPOINT=db.example.internal DB_PORT="$FAKE_PORT"
  run "$SCRIPTS/ssm-tunnel-up.sh"
  [ "$status" -eq 0 ]
  pid="$(cat "$TUNNEL_DIR/ssm-tunnel.pid")"
  grep -qxF "127.0.0.1 db.example.internal # ssm-tunnel" "$HOSTS_FILE"
  grep -q "AWS-StartPortForwardingSessionToRemoteHost" "$FAKE_LOG"
  run "$SCRIPTS/wait-for-port.sh" --port "$FAKE_PORT" --pid "$pid" --log "$TUNNEL_DIR/ssm-tunnel.log" --timeout 20 --interval 1
  [ "$status" -eq 0 ]
  run "$SCRIPTS/ssm-tunnel-down.sh"
  [ "$status" -eq 0 ]
  ! kill -0 "$pid" 2>/dev/null
  ! grep -q "ssm-tunnel" "$HOSTS_FILE"
  grep -qx "127.0.0.1 localhost" "$HOSTS_FILE"
  run "$SCRIPTS/ssm-tunnel-down.sh"
  [ "$status" -eq 0 ]
}

@test "tunnel-up: an endpoint with characters that are not valid in a hostname is rejected" {
  export BASTION_ID=i-0abc123 DB_ENDPOINT='db.example.internal"; rm -rf /' DB_PORT=5432
  run "$SCRIPTS/ssm-tunnel-up.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid in a hostname"* ]]
}

# ---- pinned downloads --------------------------------------------------------------------------------------------------

@test "install-ssm-plugin: a download whose sha256 does not match is refused and removed" {
  export SKIP_PLUGIN_INSTALL=1 FAKE_CURL_BODY="tampered"
  run "$SCRIPTS/install-ssm-plugin.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  [ ! -f "$TUNNEL_DIR/rds-ca-bundle.pem" ]
}

@test "install-ssm-plugin: versions.env pins a version and a 64-hex sha256 for every download (never latest)" {
  # shellcheck source=/dev/null
  source "$SCRIPTS/lib/versions.env"
  [[ $SSM_PLUGIN_SHA256 =~ ^[0-9a-f]{64}$ ]]
  [[ $RDS_CA_BUNDLE_SHA256 =~ ^[0-9a-f]{64}$ ]]
  [[ $SSM_PLUGIN_URL == *"/$SSM_PLUGIN_VERSION/"* ]]
  [[ $SSM_PLUGIN_URL != *latest* ]]
}
