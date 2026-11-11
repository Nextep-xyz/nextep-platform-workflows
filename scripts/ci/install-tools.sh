#!/usr/bin/env bash
# Installs the pinned CI tools (self-ci only). Every download is verified against its sha256.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/tools.env
source "$root/scripts/lib/tools.env"

dest="${TOOLS_DIR:-${RUNNER_TEMP:-/tmp}/tools}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

fetch() { # fetch <url> <sha256> <outfile>
  curl --fail --silent --show-error --location --retry 3 --output "$3" "$1"
  echo "$2  $3" | sha256sum --check --status || { echo "::error::sha256 mismatch for $1" >&2; exit 1; }
}

fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
  "$ACTIONLINT_SHA256" "$work/actionlint.tgz"
tar -xzf "$work/actionlint.tgz" -C "$dest" actionlint

fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
  "$SHELLCHECK_SHA256" "$work/shellcheck.txz"
tar -xJf "$work/shellcheck.txz" -C "$work"
install -m 0755 "$work/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$dest/shellcheck"

fetch "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  "$GITLEAKS_SHA256" "$work/gitleaks.tgz"
tar -xzf "$work/gitleaks.tgz" -C "$dest" gitleaks

fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" "$YQ_SHA256" "$dest/yq"
fetch "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" "$JQ_SHA256" "$dest/jq"
chmod +x "$dest/yq" "$dest/jq"

npm install --global --prefix "$dest/npm" "bats@${BATS_VERSION}" >/dev/null
ln -sf "$dest/npm/bin/bats" "$dest/bats"

if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$dest" >>"$GITHUB_PATH"; fi
echo "tools installed in $dest"
