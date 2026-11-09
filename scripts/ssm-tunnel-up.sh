#!/usr/bin/env bash
# Opens the SSM port-forwarding tunnel in the background and records its pid and log.
# Env: AWS_REGION, BASTION_ID, DB_ENDPOINT, DB_PORT, TUNNEL_DIR (default ${RUNNER_TEMP:-/tmp}/ssm-tunnel),
#      HOSTS_FILE (default /etc/hosts), SUDO_CMD (default sudo; empty in tests).
# Also maps 127.0.0.1 -> <db-endpoint> in the hosts file so TLS can verify the REAL hostname (verify-full).
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_env AWS_REGION BASTION_ID DB_ENDPOINT DB_PORT
tunnel_dir="${TUNNEL_DIR:-${RUNNER_TEMP:-/tmp}/ssm-tunnel}"
hosts_file="${HOSTS_FILE:-/etc/hosts}"
mkdir -p "$tunnel_dir"

# The endpoint is interpolated into JSON and into the hosts file: allow only hostname characters.
[[ $DB_ENDPOINT =~ ^[A-Za-z0-9.-]+$ ]] || die "db endpoint '$DB_ENDPOINT' contains characters that are not valid in a hostname"
[[ $DB_PORT =~ ^[0-9]{1,5}$ ]] || die "db port '$DB_PORT' is not a port number"

entry="127.0.0.1 $DB_ENDPOINT # ssm-tunnel"
if ! grep -qxF "$entry" "$hosts_file" 2>/dev/null; then
  printf '%s\n' "$entry" | ${SUDO_CMD-sudo} tee -a "$hosts_file" >/dev/null
fi
printf '%s\n' "$entry" >"$tunnel_dir/hosts-entry"

params="$(printf '{"host":["%s"],"portNumber":["%s"],"localPortNumber":["%s"]}' "$DB_ENDPOINT" "$DB_PORT" "$DB_PORT")"
aws ssm start-session --region "$AWS_REGION" --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "$params" >"$tunnel_dir/ssm-tunnel.log" 2>&1 &
echo $! >"$tunnel_dir/ssm-tunnel.pid"
log "tunnel started (pid $(cat "$tunnel_dir/ssm-tunnel.pid")), log: $tunnel_dir/ssm-tunnel.log"
