#!/usr/bin/env bash
# The package guard as a step of the platform (docs/runbook.md section 12): it runs `guardrails-command` of the caller (default `make guardrails`, the
# CLI of @nextep/cdk-guardrails) as an independent net, and maps its result BY MODE in this script, never with continue-on-error:
#   mode enforce (dev, stg)   rc 0 -> pass     rc != 0 -> the step FAILS (result fail)     command missing -> the step FAILS (result missing)
#   mode warn (prod)          rc 0 -> pass     rc != 0 -> ::warning::, exit 0 (result warn) command missing -> ::warning::, exit 0 (result missing)
# The mode is the answer of enforcement_mode for ENVIRONMENT (lib/enforcement.sh); this script never compares an environment name. It runs only when
# the repository has an IaC root (declared iac, or detected by CDK files: packages-evidence.sh iac-roots); without one the result is `skipped`.
# The REAL result travels in the output `result` (pass | fail | warn | missing | skipped): the `outcome` of a step that warns would be `success`
# and would hide the violation, so the packages policy and the evidence read the output, never the outcome.
# The command goes through run-command.sh (the one door of every caller command: it sets NEXTEP_GUARDRAILS_MODE and removes CMD from the child), but
# the `::error::` line that run-command.sh prints when it fails is NOT forwarded: in warn mode the step does not fail and an error annotation would lie.
# Env: ENVIRONMENT CMD (the command) INSTALL_DIRS PACKAGE_MANAGER ROOT_KINDS (as for packages-evidence.sh) APP_ENV APP_STAGE STACK_SUFFIX PROJECT
#      AWS_REGION (the context every command of the caller gets) GITHUB_OUTPUT
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/enforcement.sh
source "$here/lib/enforcement.sh"

mode="$(enforcement_mode "${ENVIRONMENT-}")"
cmd="${CMD-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

emit() { printf 'result=%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/stdout}"; }
# finish <result-when-enforce> <result-when-warn> <message>: the one place that maps a bad result to an exit code, by mode
finish() {
  if [[ $mode == enforce ]]; then
    emit "$1"
    printf '::error title=package-guardrails::%s\n' "$3"
    exit 1
  fi
  emit "$2"
  printf '::warning title=package-guardrails::%s (not blocking in this environment)\n' "$3"
  exit 0
}

if ! iac="$("$here/packages-evidence.sh" iac-roots 2>"$work/iac.err")"; then
  # a malformed root-kinds is reported by the policy step, which reads the same disk: this step only says it could not decide
  emit skipped
  printf '::warning title=package-guardrails::the IaC roots could not be determined, so the guard did not run: %s\n' "$(tail -n 1 "$work/iac.err" | tr -d '\r' | sed 's/^::[a-z]*[^:]*:://' | cut -c1-160)"
  exit 0
fi
if [[ -z $iac ]]; then
  log "package guardrails: no IaC root (declared iac or with CDK files), nothing to guard"
  emit skipped
  exit 0
fi
if [[ -z $cmd ]]; then
  finish missing missing "no guardrails command is configured: the repository has an IaC root and its package guard did not run (input 'guardrails-command')"
fi

set +e
CMD="$cmd" "$here/run-command.sh" guardrails 2>"$work/err" | tee "$work/out"
rc="${PIPESTATUS[0]}"
set -e
# what the runner printed on stderr, without its own failure annotation
grep -v '^::error::' "$work/err" >&2 || true
if ((rc == 0)); then
  emit pass
  exit 0
fi
exit_code="$(sed -nE "s/.*failed \(exit ([0-9]+)\).*/\1/p" "$work/err" | tail -n 1)"
if [[ ${exit_code:-} == 127 ]] || grep -qE 'No rule to make target|make: \*\*\* No rule' "$work/out" "$work/err"; then
  finish missing missing "the guardrails command does not exist in the repository (make: no such target, or command not found)"
fi
finish fail warn "the package guard reported violations or failed (exit ${exit_code:-unknown}): the guardrails command of the repository is red"
