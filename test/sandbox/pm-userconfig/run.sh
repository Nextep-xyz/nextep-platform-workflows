#!/usr/bin/env bash
# MANUAL check (not part of the suite: it installs pnpm from the network). Does npm / pnpm honour an ephemeral NPM_CONFIG_USERCONFIG that
# holds `@scope:registry=` and an `_authToken=${VAR}` REFERENCE, with the token only in the environment of the install? Against a LOCAL fake
# registry (registry.mjs, needs a token on every request like CodeArtifact): it checks the package-manager behaviour only, NOT CodeArtifact.
# The config has the same shape as the one scripts/install-dirs.sh writes. Linux shell, node and npm required.
# usage: run.sh <pnpm-spec>   (for example pnpm@9 or pnpm@10)
# expected: "+token" installs the package and the registry saw 'auth=valid'; the two controls do NOT install it.
set -uo pipefail
spec=${1:-pnpm@10}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$(mktemp -d)"
mkdir -p "$W/tools" "$W/priv" "$W/proj"
cd "$W" || exit 2
npm install --silent --no-audit --no-fund --prefix "$W/tools" "$spec" >/dev/null 2>&1 || { echo "cannot install $spec"; exit 2; }
PNPM="$W/tools/node_modules/.bin/pnpm"
echo "pnpm $("$PNPM" --version) / npm $(npm --version) / node $(node --version)"

# the private package
printf '{"name":"@example/priv","version":"1.0.0","main":"index.js"}\n' >priv/package.json
printf 'module.exports = "priv-ok";\n' >priv/index.js
(cd priv && npm pack --silent >/dev/null 2>&1) && TARBALL="$W/priv/example-priv-1.0.0.tgz"
[[ -f $TARBALL ]] || { echo "no tarball"; exit 2; }

PORT=48731
TOKEN="tok-ephemeral-$RANDOM$RANDOM"
LOG="$W/registry.log"
: >"$LOG"
node "$here/registry.mjs" "$PORT" "$TARBALL" "$TOKEN" "$LOG" &
REG=$!
trap 'kill $REG 2>/dev/null; rm -rf "$W"' EXIT
for _ in $(seq 1 30); do grep -q listening "$LOG" && break; sleep 0.2; done

# the ephemeral user config: a REFERENCE to the token, never the value (same shape as scripts/install-dirs.sh)
UC="$W/ephemeral.npmrc"
# shellcheck disable=SC2016
printf '@example:registry=http://localhost:%s/\n//localhost:%s/:_authToken=${CODEARTIFACT_AUTH_TOKEN}\n' "$PORT" "$PORT" >"$UC"
grep -q "$TOKEN" "$UC" && { echo "BUG: the config holds the token"; exit 3; }

cd "$W/proj" || exit 2
printf '{"name":"proj","version":"0.0.0","private":true,"dependencies":{"@example/priv":"1.0.0"}}\n' >package.json
HOME_BAK=$HOME
export HOME="$W/home"; mkdir -p "$HOME"   # a clean HOME: no ~/.npmrc, nothing else to fall back on

check() { # check <label> <command...>: install, then prove the package is there and the token was sent
  local label=$1; shift
  : >"$LOG"
  rm -rf node_modules "$HOME/.local/share/pnpm" "$HOME/.cache" "$HOME/.npm" "$HOME/.pnpm-store"
  if "$@" >"$W/out.txt" 2>&1; then rc=0; else rc=$?; fi
  local pkg="MISSING"
  [[ -f node_modules/@example/priv/index.js ]] && pkg="installed"
  echo "[$label] exit=$rc package=$pkg registry-saw: $(grep -v listening "$LOG" | sort | uniq -c | tr -s ' ' | paste -sd';' -)"
  grep -q "$TOKEN" "$W/out.txt" && echo "[$label] WARNING: the token appears in the install output"
  [[ $rc -eq 0 && $pkg == installed ]]
}

echo "--- pnpm: lockfile created WITH the token (to have something to be frozen against)"
NPM_CONFIG_USERCONFIG="$UC" CODEARTIFACT_AUTH_TOKEN="$TOKEN" "$PNPM" install --lockfile-only >"$W/out.txt" 2>&1 || { echo "lockfile step failed:"; tail -5 "$W/out.txt"; }
echo "--- 1. pnpm install --frozen-lockfile, ephemeral config + token in env"
check "pnpm +token" env NPM_CONFIG_USERCONFIG="$UC" CODEARTIFACT_AUTH_TOKEN="$TOKEN" "$PNPM" install --frozen-lockfile
echo "--- 2. the control: the same install WITHOUT the config must NOT reach the private package"
check "pnpm control (no config)" env -u NPM_CONFIG_USERCONFIG -u CODEARTIFACT_AUTH_TOKEN "$PNPM" install --frozen-lockfile && echo "[control] UNEXPECTED: it installed without credentials"
echo "--- 3. the config without the token in env: the reference expands to nothing, the registry must say 401"
check "pnpm config, no token" env -u CODEARTIFACT_AUTH_TOKEN NPM_CONFIG_USERCONFIG="$UC" "$PNPM" install --frozen-lockfile && echo "[no-token] UNEXPECTED: it installed"

echo "--- npm: lockfile + npm ci"
rm -f pnpm-lock.yaml
NPM_CONFIG_USERCONFIG="$UC" CODEARTIFACT_AUTH_TOKEN="$TOKEN" npm install --package-lock-only --silent >"$W/out.txt" 2>&1 || { echo "npm lock step failed:"; tail -5 "$W/out.txt"; }
echo "--- 4. npm ci, ephemeral config + token in env"
check "npm ci +token" env NPM_CONFIG_USERCONFIG="$UC" CODEARTIFACT_AUTH_TOKEN="$TOKEN" npm ci
export HOME=$HOME_BAK
