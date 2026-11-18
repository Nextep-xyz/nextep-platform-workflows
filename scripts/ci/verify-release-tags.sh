#!/usr/bin/env bash
# Verifies, AFTER the push, that the release landed the way release.yml promises (replaces three manual commands):
#   verify-release-tags.sh <X.Y.Z> <source-sha>
# vX.Y.Z and the alias vX, as the REMOTE sees them, must point to the same commit, and that commit must be a child of
# <source-sha> (the release commit is built on top of the source commit). Fails naming what it compared; the tags are already
# published when this runs (they are never moved or deleted), so a failure here means "investigate", not "retry".
# Env: RELEASE_REMOTE (default origin), GITHUB_STEP_SUMMARY (optional: a table of what was compared is appended).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$root/scripts/lib/common.sh"

version="${1:?usage: verify-release-tags.sh <X.Y.Z> <source-sha>}"
source_sha="${2:?usage: verify-release-tags.sh <X.Y.Z> <source-sha>}"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "verify-release-tags: version must be X.Y.Z (got '$version')"
[[ $source_sha =~ ^[0-9a-f]{40}$ ]] || die "verify-release-tags: <source-sha> must be a full 40-hex commit sha"
remote="${RELEASE_REMOTE:-origin}"
alias_tag="v${version%%.*}"
full_tag="v${version}"

# remote_commit <tag>: the commit the remote tag points to (the peeled value when the tag is annotated).
remote_commit() {
  local out direct='' peeled='' sha ref
  out=$(git ls-remote "$remote" "refs/tags/$1" "refs/tags/$1^{}") || die "verify-release-tags: cannot read the tags of '$remote'"
  while read -r sha ref; do
    [[ -n $ref ]] || continue
    if [[ $ref == "refs/tags/$1^{}" ]]; then peeled=$sha; elif [[ $ref == "refs/tags/$1" ]]; then direct=$sha; fi
  done <<<"$out"
  printf '%s' "${peeled:-$direct}"
}

full_commit=$(remote_commit "$full_tag")
alias_commit=$(remote_commit "$alias_tag")
[[ -n $full_commit ]] || die "verify-release-tags: $full_tag is not on '$remote'"
[[ -n $alias_commit ]] || die "verify-release-tags: the alias $alias_tag is not on '$remote'"
parent=$(git rev-parse --verify --quiet "${full_commit}^" 2>/dev/null) ||
  die "verify-release-tags: the commit of $full_tag (${full_commit}) is not in this clone or has no parent"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    printf '\n### Published tags\n\n'
    printf '| ref | commit |\n|---|---|\n'
    # shellcheck disable=SC2016 # the backticks are markdown, not command substitutions
    printf '| `%s` | `%s` |\n| `%s` | `%s` |\n| parent of `%s` | `%s` |\n| released source | `%s` |\n' \
      "$full_tag" "$full_commit" "$alias_tag" "$alias_commit" "$full_tag" "$parent" "$source_sha"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[[ $full_commit == "$alias_commit" ]] ||
  die "verify-release-tags: $full_tag (${full_commit}) and the alias $alias_tag (${alias_commit}) do not point to the same commit"
[[ $parent == "$source_sha" ]] ||
  die "verify-release-tags: the parent of $full_tag is ${parent}, not the released source ${source_sha}"
log "verified: $full_tag and $alias_tag -> ${full_commit}, a child of the released source ${source_sha}"
