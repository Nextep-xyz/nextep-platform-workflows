#!/usr/bin/env bash
# Polls a TCP port until it accepts connections. Never a fixed sleep.
#   wait-for-port.sh --port N [--host H] [--timeout S] [--interval S] [--pid PID] [--log FILE]
# If --pid is given and that process dies, fails immediately printing the log. On timeout, fails printing the log.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

host=127.0.0.1 port="" timeout=60 interval=2 pid="" logfile=""
while (($#)); do
  case "$1" in
    --host) host=$2 ;;
    --port) port=$2 ;;
    --timeout) timeout=$2 ;;
    --interval) interval=$2 ;;
    --pid) pid=$2 ;;
    --log) logfile=$2 ;;
    *) die "wait-for-port: unknown argument $1" ;;
  esac
  shift 2
done
[[ $port =~ ^[0-9]+$ ]] || die "wait-for-port: --port is required"

show_log() {
  if [[ -n $logfile && -f $logfile ]]; then
    echo "----- tunnel log ($logfile) -----" >&2
    cat "$logfile" >&2
    echo "----- end of tunnel log -----" >&2
  fi
}

start=$SECONDS
while :; do
  if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then
    show_log
    die "the tunnel process (pid $pid) died before $host:$port opened"
  fi
  if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
    log "$host:$port is accepting connections"
    exit 0
  fi
  if ((SECONDS - start >= timeout)); then
    show_log
    die "timeout: $host:$port did not open within ${timeout}s"
  fi
  sleep "$interval"
done
