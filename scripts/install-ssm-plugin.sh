#!/usr/bin/env bash
# Installs the pinned Session Manager plugin and downloads the pinned RDS CA bundle, both verified by sha256.
# Versions live in scripts/lib/versions.env. Never "latest", never unverified.
# Env: TUNNEL_DIR (default ${RUNNER_TEMP:-/tmp}/ssm-tunnel), SUDO_CMD (default sudo; empty to skip, for tests),
#      SKIP_PLUGIN_INSTALL=1 (tests: only fetch the CA bundle).
# Output (GITHUB_OUTPUT when set): ca-bundle (path).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/versions.env
source "$here/lib/versions.env"

tunnel_dir="${TUNNEL_DIR:-${RUNNER_TEMP:-/tmp}/ssm-tunnel}"
mkdir -p "$tunnel_dir"

if [[ ${SKIP_PLUGIN_INSTALL:-} != 1 ]]; then
  deb="$tunnel_dir/session-manager-plugin.deb"
  download_verified "$SSM_PLUGIN_URL" "$SSM_PLUGIN_SHA256" "$deb"
  ${SUDO_CMD-sudo} dpkg -i "$deb" >/dev/null
  log "Session Manager plugin $SSM_PLUGIN_VERSION installed"
fi

bundle="$tunnel_dir/rds-ca-bundle.pem"
download_verified "$RDS_CA_BUNDLE_URL" "$RDS_CA_BUNDLE_SHA256" "$bundle"
log "RDS CA bundle verified"
printf 'ca-bundle=%s\n' "$bundle" >>"${GITHUB_OUTPUT:-/dev/stdout}"
