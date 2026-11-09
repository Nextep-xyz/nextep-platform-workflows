#!/usr/bin/env bash
# Tears the tunnel down. Idempotent: safe to call twice, or when nothing was started.
# Kills the tunnel process, removes the hosts-file entry and deletes the temporary files.
# Env: TUNNEL_DIR (default ${RUNNER_TEMP:-/tmp}/ssm-tunnel), HOSTS_FILE (default /etc/hosts), SUDO_CMD (default sudo).
set -uo pipefail

tunnel_dir="${TUNNEL_DIR:-${RUNNER_TEMP:-/tmp}/ssm-tunnel}"
hosts_file="${HOSTS_FILE:-/etc/hosts}"

if [[ -f $tunnel_dir/ssm-tunnel.pid ]]; then
  pid="$(cat "$tunnel_dir/ssm-tunnel.pid")"
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
fi

if [[ -f $tunnel_dir/hosts-entry && -f $hosts_file ]]; then
  entry="$(cat "$tunnel_dir/hosts-entry")"
  tmp="$(mktemp)"
  grep -vxF "$entry" "$hosts_file" >"$tmp" || true
  if ! cmp -s "$tmp" "$hosts_file"; then
    ${SUDO_CMD-sudo} cp "$tmp" "$hosts_file" || echo "::warning::could not remove the tunnel entry from $hosts_file" >&2
  fi
  rm -f "$tmp"
fi

rm -f "$tunnel_dir/ssm-tunnel.pid" "$tunnel_dir/hosts-entry"
# the log is kept on purpose (diagnostics); it never contains credentials
echo "tunnel torn down"
exit 0
