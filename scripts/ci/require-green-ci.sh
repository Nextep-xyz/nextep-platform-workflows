#!/usr/bin/env bash
# Refuses to release a commit whose CI is not green (guard RA9 of the release automation).
#
# The jobs that must be green are READ from the CI workflow of this repository (jobs.*.name of $SELF_CI_FILE), never written here:
# a new required job is covered the day it is added to that file. Polls the check-runs of the commit until every one of them has
# finished (up to $CI_WAIT_SECONDS), and fails if any finished with something other than `success`, if one never shows up, or if
# the workflow declares no jobs at all (a guard over nothing proves nothing).
#
# Env: GH_TOKEN (read-only `checks: read` is enough), GITHUB_REPOSITORY, SOURCE_SHA (40-hex),
#      SELF_CI_FILE (default .github/workflows/self-ci.yml), CI_WAIT_SECONDS (default 600), CI_POLL_SECONDS (default 20).
# Prints one status line per required job; never prints the API response or the token.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$root/scripts/lib/common.sh"

require_env SOURCE_SHA GITHUB_REPOSITORY
[[ $SOURCE_SHA =~ ^[0-9a-f]{40}$ ]] || die "require-green-ci: SOURCE_SHA must be a full 40-hex commit sha"
wf="${SELF_CI_FILE:-$root/.github/workflows/self-ci.yml}"
[[ -f $wf ]] || die "require-green-ci: the CI workflow '$wf' does not exist"
wait_seconds="${CI_WAIT_SECONDS:-600}"
poll_seconds="${CI_POLL_SECONDS:-20}"
[[ $wait_seconds =~ ^[0-9]+$ ]] || die "require-green-ci: CI_WAIT_SECONDS must be a whole number of seconds"

mapfile -t required < <(yq -r '.jobs | to_entries[] | (.value.name // .key)' "$wf")
((${#required[@]} > 0)) || die "require-green-ci: 0 jobs discovered in $wf (a guard over nothing proves nothing)"
log "required jobs, read from $(basename "$wf"): ${required[*]}"

deadline=$((SECONDS + wait_seconds))
while :; do
  rows=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/commits/${SOURCE_SHA}/check-runs?filter=latest&per_page=100" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv') ||
    die "require-green-ci: could not read the check-runs of ${SOURCE_SHA}"

  failed=() pending=()
  for name in "${required[@]}"; do
    seen=0 running=0 bad=''
    while IFS=$'\t' read -r n s c; do
      [[ $n == "$name" ]] || continue
      seen=1
      if [[ $s != completed ]]; then running=1; elif [[ $c != success ]]; then bad=$c; fi
    done <<<"$rows"
    if [[ -n $bad ]]; then
      failed+=("$name ($bad)")
    elif ((seen == 0)); then
      pending+=("$name (not reported yet)")
    elif ((running == 1)); then
      pending+=("$name (running)")
    fi
  done

  ((${#failed[@]} == 0)) || die "the CI of ${SOURCE_SHA} is not green, so it is not released. Not successful: ${failed[*]}"
  if ((${#pending[@]} == 0)); then
    log "CI is green on ${SOURCE_SHA}: ${required[*]}"
    exit 0
  fi
  if ((SECONDS >= deadline)); then
    die "the CI of ${SOURCE_SHA} did not finish within ${wait_seconds}s. Waiting for: ${pending[*]}"
  fi
  log "waiting for: ${pending[*]}"
  sleep "$poll_seconds"
done
