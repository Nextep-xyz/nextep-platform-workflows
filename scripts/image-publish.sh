#!/usr/bin/env bash
# Logic of lego-aws-image-publish: builds the image of the caller repository on the push of a version tag, pushes it to ECR as <X.Y.Z>
# and reads its digest. One subcommand per step so each one is a step of the workflow and a bats test with `aws` and `docker` fakes.
#   image-publish.sh validate   shape of the inputs and of the triggering ref (a tag <tag-prefix>X.Y.Z); writes `version` to GITHUB_OUTPUT
#   image-publish.sh build      build-push-image.sh with the tag = the version; NEVER pushes `latest` (ENVIRONMENT=release)
#   image-publish.sh digest     describe-images (json) -> `version`, `image` and `digest` to GITHUB_OUTPUT and a summary
# Inputs arrive as one INPUTS_JSON object (the composite hands toJSON(inputs)) or as INPUT_<NAME>; EVENT_NAME, REF_TYPE and REF_NAME
# (github.event_name / ref_type / ref_name) come through env:. `build` and `digest` also need VERSION and REGISTRY (outputs of earlier steps).
# The workflow has no secret inputs, so nothing sensitive travels in INPUTS_JSON; the role ARN is never printed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

cmd="${1:?usage: image-publish.sh <validate|build|digest>}"

if [[ -n ${INPUTS_JSON:-} ]]; then
  while IFS= read -r key; do
    name="${key^^}"
    printf -v "INPUT_${name//-/_}" '%s' "$(jq -r --arg k "$key" '.[$k] | tostring' <<<"$INPUTS_JSON")"
    export "INPUT_${name//-/_}"
  done < <(jq -r 'keys[]' <<<"$INPUTS_JSON")
fi

errs=()
err() { errs+=("$*"); }
val() { input_env "$1"; }
finish() { # prints every problem at once, then fails
  local e
  ((${#errs[@]} == 0)) && return 0
  for e in "${errs[@]}"; do printf '::error::%s\n' "$e" >&2; done
  exit 1
}

# The only versions this workflow publishes: X.Y.Z, no leading zeros (semver), no suffix. The tag is <tag-prefix><version>.
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
REPO_RE='^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$'
ROLE_RE='^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$'
PATH_RE='^[A-Za-z0-9._/-]+$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'

# safe_relative <input-name> <value>: a path inside the checkout (no absolute path, no `..` segment).
safe_relative() {
  local name=$1 v=$2
  if [[ -z $v ]]; then err "input '$name' must not be empty"; return; fi
  [[ $v =~ $PATH_RE ]] || { err "input '$name' has characters outside [A-Za-z0-9._/-]"; return; }
  [[ $v != /* ]] || err "input '$name' must be relative to the repository root"
  if [[ /$v/ == *"/../"* ]]; then err "input '$name' must not contain '..'"; fi
}

validate() {
  local project repo role region prefix platform dockerfile context tag ver=""
  project="$(val project)"
  repo="$(val ecr-repository)"
  role="$(val role-arn)"
  region="$(val aws-region)"
  prefix="$(val tag-prefix)"
  platform="$(val platform)"
  dockerfile="$(val dockerfile)"
  context="$(val docker-context)"

  [[ $project =~ ^[a-z][a-z0-9-]{1,15}$ ]] || err "input 'project' must match ^[a-z][a-z0-9-]{1,15}\$"
  if [[ -z $repo ]]; then
    err "input 'ecr-repository' is required"
  else
    { [[ $repo =~ $REPO_RE ]] && ((${#repo} <= 256)); } || err "input 'ecr-repository' is not a valid ECR repository name (lower case, a literal name, no placeholders)"
  fi
  # The role comes from a repository variable. Only its shape is checked; the value is never echoed (it carries the account id).
  [[ $role =~ $ROLE_RE ]] || err "input 'role-arn' is not the ARN of an IAM role: pass it from a repository variable (vars.<NAME>), never a literal"
  [[ $region =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || err "input 'aws-region' is not a region name"
  [[ $prefix =~ ^[A-Za-z0-9._-]{1,32}$ ]] || err "input 'tag-prefix' must match ^[A-Za-z0-9._-]{1,32}\$"
  case "$platform" in linux/amd64 | linux/arm64) ;; *) err "input 'platform' must be linux/amd64 or linux/arm64" ;; esac
  safe_relative dockerfile "$dockerfile"
  safe_relative docker-context "$context"

  # The trigger: the push of a version tag, nothing else (a branch, a pull request or a manual run is not a release).
  if [[ ${EVENT_NAME:-} != push || ${REF_TYPE:-} != tag ]]; then
    err "this workflow runs only on the push of a version tag (event '${EVENT_NAME:-}', ref type '${REF_TYPE:-}'): a branch, a pull request or a manual run is not a release"
  else
    tag="${REF_NAME:-}"
    if [[ -n $prefix && $tag == "$prefix"* ]]; then
      ver="${tag#"$prefix"}"
      [[ $ver =~ $VERSION_RE ]] || err "tag '$tag' is not <tag-prefix><X.Y.Z> (version '$ver' does not match X.Y.Z)"
    else
      err "tag '$tag' does not start with the tag-prefix '$prefix'"
    fi
  fi

  # The files the build reads must exist in the checkout (a typo is a failure BEFORE any role is assumed).
  if [[ $dockerfile =~ $PATH_RE && /$dockerfile/ != *"/../"* && $dockerfile != /* ]]; then
    [[ -f $dockerfile ]] || err "dockerfile '$dockerfile' does not exist in the checkout"
  fi
  if [[ $context =~ $PATH_RE && /$context/ != *"/../"* && $context != /* ]]; then
    [[ -d $context ]] || err "docker-context '$context' does not exist in the checkout"
  fi
  finish
  printf 'version=%s\n' "$ver" >>"${GITHUB_OUTPUT:-/dev/stdout}"
}

build() {
  require_env VERSION REGISTRY
  # shellcheck disable=SC2153  # VERSION is an input of the composite (env:), not a misspelling of a local
  [[ $VERSION =~ $VERSION_RE ]] || die "invalid version '$VERSION'"
  # ENVIRONMENT=release: build-push-image.sh adds `latest` only when it is `dev`, so a release image never carries it (gate GI-F3).
  AWS_REGION="$(val aws-region)" \
    REGISTRY="$REGISTRY" \
    ECR_REPOSITORY="$(val ecr-repository)" \
    IMAGE_TAG="$VERSION" \
    ENVIRONMENT=release \
    DOCKERFILE="$(val dockerfile)" \
    BUILD_CONTEXT="$(val docker-context)" \
    BUILD_PLATFORM="$(val platform)" \
    "$here/build-push-image.sh"
}

digest() {
  require_env VERSION REGISTRY
  [[ $VERSION =~ $VERSION_RE ]] || die "invalid version '$VERSION'"
  local repo out d image
  repo="$(val ecr-repository)"
  out="$(aws ecr describe-images --region "$(val aws-region)" --repository-name "$repo" --image-ids "imageTag=$VERSION" --output json)" ||
    die "could not read '$repo:$VERSION' from ECR (describe-images)"
  d="$(jq -r '.imageDetails[0].imageDigest // empty' <<<"$out")"
  [[ $d =~ $DIGEST_RE ]] || die "ECR returned no valid digest for '$repo:$VERSION' (got '${d:-nothing}')"
  image="$REGISTRY/$repo:$VERSION"
  {
    printf 'version=%s\n' "$VERSION"
    printf 'image=%s\n' "$image"
    printf 'digest=%s\n' "$d"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
  {
    printf '### Image published\n\n'
    printf '| | |\n|---|---|\n'
    # shellcheck disable=SC2016  # the backticks are markdown, not a command substitution
    printf '| version | `%s` |\n| image | `%s` |\n| digest | `%s` |\n\n' "$VERSION" "$image" "$d"
    printf 'Pin it in the consumer as an exact version and this digest (a tag alone is not an identity).\n'
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  log "published $repo:$VERSION as $d"
}

case "$cmd" in
  validate) validate ;;
  build) build ;;
  digest) digest ;;
  *) die "unknown command '$cmd' (validate, build or digest)" ;;
esac
