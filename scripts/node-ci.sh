#!/usr/bin/env bash
# Logic of the Node steps of lego-node-ci and of the gate of lego-package-release. One subcommand per step.
#   node-ci.sh test        masks the names of INTERNAL_DENYLIST (when present), then runs `pnpm test`
#   node-ci.sh typecheck   runs `pnpm typecheck`
# INTERNAL_DENYLIST (optional) and GATE_FORK_PR reach `pnpm test` through the environment of the step: the public-names gate of the
# caller reads them there. Nothing here prints them: every name is registered as a mask BEFORE the tests run.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cmd="${1:?usage: node-ci.sh <test|typecheck>}"

case "$cmd" in
  test)
    # The list is newline or comma separated (the same shape the gate parses). A secret registered as a whole is masked as a whole,
    # but a line of it printed on its own is not guaranteed to be: each name is masked by itself.
    if [[ -n ${INTERNAL_DENYLIST:-} ]]; then
      while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        mask "$name"
      done < <(printf '%s\n' "$INTERNAL_DENYLIST" | tr ',' '\n')
    fi
    pnpm test || die "'pnpm test' failed"
    ;;
  typecheck)
    pnpm typecheck || die "'pnpm typecheck' failed"
    ;;
  *) die "node-ci: unknown subcommand '$cmd'" ;;
esac
