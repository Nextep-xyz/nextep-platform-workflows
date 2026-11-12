# shellcheck shell=bash
# Shared rules of the telemetry scripts (and of validate-inputs.sh). Source it; it prints nothing.

# telemetry_valid_audience <value>: a plain slug. No dot, colon or slash: that excludes the default audience of every cloud
# provider (AWS STS, Azure token exchange, workload identity pools), so this job cannot be used to mint a token for one of
# them (SPEC telemetria-dora 3.2).
telemetry_valid_audience() { [[ ${1:-} =~ ^[a-z0-9][a-z0-9-]{2,62}$ ]]; }

# telemetry_valid_url <value>: https, a host, an optional port and an optional path. No credentials, query, fragment or space.
telemetry_valid_url() {
  [[ ${1:-} =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]
}

# telemetry_jwt_payload <jwt>: prints the JSON payload of a JWT (no signature check: the token comes from the runner itself).
telemetry_jwt_payload() {
  local jwt=${1:-} p
  [[ $jwt =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$ ]] || return 1
  p="$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')"
  case $((${#p} % 4)) in
    2) p+='==' ;;
    3) p+='=' ;;
    1) return 1 ;;
  esac
  printf '%s' "$p" | base64 -d 2>/dev/null
}

# telemetry_workflow_ref_ok <job_workflow_ref>: <owner>/<repo>/.github/workflows/lego-<name>.yml@<ref>
telemetry_workflow_ref_ok() {
  [[ ${1:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/lego-[a-z0-9-]+\.yml@refs/[A-Za-z0-9_./-]{1,90}$ ]]
}

# telemetry_sanitize <value> <max>: keeps [A-Za-z0-9_.-] only (for a value that comes from a response and goes into a log)
telemetry_sanitize() { printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_.-' | head -c "${2:-64}"; }

# telemetry_summary <markdown...>: appends to the step summary when there is one
telemetry_summary() { [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"; }

# telemetry_output <name> <value>: step output (never a secret)
telemetry_output() { [[ -z ${GITHUB_OUTPUT:-} ]] || printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; }
