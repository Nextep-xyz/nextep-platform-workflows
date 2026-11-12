#!/usr/bin/env bash
# Telemetry: the commit data of the run, with ONE call to the commits endpoint and the job's own token (contents: read).
# No checkout, no git. Leaves "$TELEMETRY_DIR/telemetry-commits.json" = {tree_sha, commit_at, ancestry: [{sha, at}]}
# (newest first, at most 100) or NO file when anything is unexpected. Exit code is ALWAYS 0: telemetry never breaks a pipeline.
# Env: GITHUB_REPOSITORY, GITHUB_SHA, GH_TOKEN (the job's token), GITHUB_API_URL (default https://api.github.com), TELEMETRY_DIR.
#
# Deliberately NO `set -e`: a failure here must end in a warning, never in a red job.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

dir="${TELEMETRY_DIR:-${RUNNER_TEMP:-/tmp}/telemetry}"
out="$dir/telemetry-commits.json"
raw="$dir/telemetry-commits-raw.json"
sha_re='^[0-9a-f]{40}$'
ts_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

fetch() {
  mkdir -p "$dir" && rm -f "$out" "$raw" || return 1
  [[ -n ${GH_TOKEN:-} ]] || { warn "Telemetry: no token for the commits endpoint; the event is not sent"; return 1; }
  [[ ${GITHUB_SHA:-} =~ $sha_re ]] || { warn "Telemetry: GITHUB_SHA is not a 40-hex commit; the event is not sent"; return 1; }
  [[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { warn "Telemetry: GITHUB_REPOSITORY is malformed; the event is not sent"; return 1; }
  local api_default='https://api.github.com'
  local api="${GITHUB_API_URL:-$api_default}"

  # ONE call. The token travels in the request config (stdin), never in the arguments.
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
    curl --silent --show-error --fail --connect-timeout 5 --max-time 10 --retry 2 --retry-delay 2 -K - \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      --output "$raw" "${api%/}/repos/${GITHUB_REPOSITORY}/commits?sha=${GITHUB_SHA}&per_page=100" ||
    { warn "Telemetry: the commits endpoint did not answer; the event is not sent"; return 1; }

  jq -ce --arg sha "$GITHUB_SHA" --arg sha_re "$sha_re" --arg ts_re "$ts_re" '
    if (type == "array" and length > 0 and .[0].sha == $sha
        and (.[0].commit.tree.sha | type == "string" and test($sha_re))
        and (.[0].commit.committer.date | type == "string" and test($ts_re)))
    then {
      tree_sha: .[0].commit.tree.sha,
      commit_at: .[0].commit.committer.date,
      ancestry: [ .[:100][] | select((.sha | type == "string" and test($sha_re)) and (.commit.committer.date | type == "string" and test($ts_re)))
                  | {sha: .sha, at: .commit.committer.date} ]
    } else error("unexpected answer") end' "$raw" >"$out" 2>/dev/null ||
    { rm -f "$out"; warn "Telemetry: the commits answer is not the expected one (first commit is not the run commit or the data is malformed); the event is not sent"; return 1; }
  return 0
}

fetch
rm -f "$raw"
exit 0
