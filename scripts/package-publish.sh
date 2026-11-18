#!/usr/bin/env bash
# Logic of lego-aws-package-publish: publishes an npm package to AWS CodeArtifact. One subcommand per step so each one is a
# step of the workflow and a bats test with `aws` and `npm` fakes.
#   package-publish.sh validate         shape of the inputs and of the triggering ref (a tag)
#   package-publish.sh check-manifest   package.json: scope, version (X.Y.Z or X.Y.Z-dev.N), tag == <tag-prefix><version> (GR12), no publishConfig.registry
#   package-publish.sh scan-tarball     what `npm pack` would ship holds no CodeArtifact URL and no 12-digit account id
#   package-publish.sh token            get-authorization-token + endpoint; the token is MASKED, then written to GITHUB_OUTPUT
#   package-publish.sh precheck         the version must not exist yet in the repository
#   package-publish.sh publish          npm publish with the token only in this process' environment (GR15); --tag dev on a X.Y.Z-dev.N
#   package-publish.sh verify           describe-package-version must say Published; writes a summary without secrets
# Inputs arrive as INPUT_<NAME> (dashes -> underscores, or one INPUTS_JSON object) plus REF_TYPE and REF_NAME (github.ref_type / github.ref_name), all
# through env:. `publish` also needs CODEARTIFACT_AUTH_TOKEN and CODEARTIFACT_ENDPOINT (outputs of `token`).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

cmd="${1:?usage: package-publish.sh <validate|check-manifest|scan-tarball|token|precheck|publish|verify>}"

# The composites hand every workflow input as one JSON object (INPUTS_JSON); expose them as INPUT_<NAME>. The workflow has
# no secret inputs (GR15), so nothing sensitive travels in it.
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

package_dir() {
  local d
  d="$(val package-dir)"
  [[ -n $d ]] || d=.
  printf '%s' "$d"
}

# Splits the package name into the CodeArtifact namespace (the scope without '@') and the package (the rest).
split_name() { # split_name <@scope/name> -> sets PKG_NAMESPACE and PKG_NAME
  local full=$1
  PKG_NAMESPACE="${full%%/*}"
  PKG_NAMESPACE="${PKG_NAMESPACE#@}"
  PKG_NAME="${full#*/}"
}

read_manifest() { # read_manifest -> sets MF_NAME and MF_VERSION; dies when there is no package.json
  local dir manifest
  dir="$(package_dir)"
  manifest="$dir/package.json"
  [[ -f $manifest ]] || die "package-dir '$dir' has no package.json"
  jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || die "$manifest is not a JSON object"
  MF_NAME="$(jq -r '.name // empty' "$manifest")"
  MF_VERSION="$(jq -r '.version // empty' "$manifest")"
}

# The only versions this workflow publishes: X.Y.Z (stable) and X.Y.Z-dev.N (pre-release, dist-tag "dev"). The numeric part of the
# pre-release has no leading zero (semver), so npm accepts what this check accepts.
STABLE_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
DEV_RE='^[0-9]+\.[0-9]+\.[0-9]+-dev\.(0|[1-9][0-9]*)$'

aws_ca() { # aws_ca <args...>: aws codeartifact with the domain, the owner and the region of the inputs
  aws codeartifact "$1" --region "$(val aws-region)" --domain "$(val codeartifact-domain)" \
    --domain-owner "$(val codeartifact-domain-owner)" "${@:2}"
}

describe_version() { # describe_version -> prints the JSON; returns 0 found, 3 not found; dies on any other error
  local out rc=0 err_file
  err_file="$(mktemp)"
  split_name "$MF_NAME"
  out="$(aws_ca describe-package-version --repository "$(val codeartifact-repository)" --format npm \
    --namespace "$PKG_NAMESPACE" --package "$PKG_NAME" --package-version "$MF_VERSION" --output json 2>"$err_file")" || rc=$?
  if ((rc != 0)); then
    if grep -q 'ResourceNotFoundException' "$err_file"; then
      rm -f "$err_file"
      return 3
    fi
    cat "$err_file" >&2
    rm -f "$err_file"
    die "describe-package-version failed for $MF_NAME@$MF_VERSION (neither found nor 'not found': permissions or an outage); nothing was published"
  fi
  rm -f "$err_file"
  printf '%s' "$out"
}

case "$cmd" in
  validate)
    project="$(val project)"
    dir="$(package_dir)"
    scope="$(val package-scope)"
    prefix="$(val tag-prefix)"
    [[ $project =~ ^[a-z][a-z0-9-]{1,15}$ ]] || err "input 'project' must match ^[a-z][a-z0-9-]{1,15}\$ (got '$project')"
    if [[ $dir != . && ! $dir =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || [[ $dir == *..* ]] || [[ $dir == */ ]]; then
      err "input 'package-dir' must be '.' or a relative path with no '..', no spaces and no trailing '/' (got '$dir')"
    fi
    [[ $scope =~ ^@[a-z0-9][a-z0-9._-]*$ ]] || err "input 'package-scope' must be an npm scope such as @example (got '$scope')"
    [[ $prefix =~ ^([a-z][a-z0-9-]*-)?v$ ]] || err "input 'tag-prefix' must end in 'v' and use lower case, for example shop-lib-v (got '$prefix')"
    role="$(val role-arn)"
    if [[ -z $role ]]; then
      err "input 'role-arn' is required (pass it from a repository variable)"
    elif [[ ! $role =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]]; then
      err "input 'role-arn' is not an IAM role ARN (value not shown)"
    fi
    [[ "$(val codeartifact-domain)" =~ ^[a-z][a-z0-9-]{0,48}[a-z0-9]$ ]] || err "input 'codeartifact-domain' is missing or not a CodeArtifact domain name (pass it from a repository variable)"
    [[ "$(val codeartifact-domain-owner)" =~ ^[0-9]{12}$ ]] || err "input 'codeartifact-domain-owner' is missing or not a 12-digit account id (pass it from a repository variable; value not shown)"
    [[ "$(val codeartifact-repository)" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,99}$ ]] || err "input 'codeartifact-repository' is missing or not a CodeArtifact repository name (pass it from a repository variable)"
    [[ "$(val aws-region)" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || err "input 'aws-region' is not a region name (got '$(val aws-region)')"
    case "$(val package-manager)" in npm | pnpm) ;; *) err "input 'package-manager' must be npm or pnpm (got '$(val package-manager)')" ;; esac
    [[ "$(val node-version)" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || err "input 'node-version' must be a version such as 22 or 22.11 (got '$(val node-version)')"
    install_dirs="$(val install-dirs)"
    if [[ -n $install_dirs ]]; then
      IFS=',' read -r -a _dirs <<<"$install_dirs"
      for d in "${_dirs[@]}"; do
        if [[ $d != . && ! $d =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || [[ $d == *..* ]] || [[ $d == */ ]]; then
          err "input 'install-dirs' has an invalid directory '$d' (comma separated relative paths, no '..', no spaces, no trailing '/')"
        fi
      done
    fi
    # The gate runs the tests of the package: an empty command would turn it into a gate that checks nothing.
    [[ -n "$(val test-command)" ]] || err "input 'test-command' must not be empty (the gate runs the tests of the package; pass 'true' explicitly if there are none)"
    # The caller decides when it runs; the only legitimate trigger is the push of a version tag.
    [[ ${REF_TYPE:-} == tag ]] || err "this workflow publishes from a version tag only (got ref type '${REF_TYPE:-}', ref '${REF_NAME:-}')"
    finish
    log "inputs are valid"
    ;;

  check-manifest)
    read_manifest
    dir="$(package_dir)"
    manifest="$dir/package.json"
    scope="$(val package-scope)"
    prefix="$(val tag-prefix)"
    if [[ -z $MF_NAME ]]; then
      err "$manifest has no 'name'"
    elif [[ $MF_NAME != "$scope"/* || ! ${MF_NAME#"$scope"/} =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
      err "package name '$MF_NAME' must be '$scope/<name>' (input package-scope)"
    fi
    if [[ ! $MF_VERSION =~ $STABLE_RE && ! $MF_VERSION =~ $DEV_RE ]]; then
      err "package.json version '$MF_VERSION' must be X.Y.Z or X.Y.Z-dev.N (the only pre-release suffix accepted is -dev.N, N a number without leading zeros; any other suffix and any build metadata is refused)"
    else
      # GR12: the tag and the manifest agree BEFORE anything is published, and the message names both values.
      expected="${prefix}${MF_VERSION}"
      [[ ${REF_NAME:-} == "$expected" ]] ||
        err "tag '${REF_NAME:-}' does not match the package.json version '$MF_VERSION': the tag for this version is '$expected' (tag-prefix '$prefix' + version)"
    fi
    jq -e '.publishConfig.registry == null' "$manifest" >/dev/null ||
      err "$manifest sets publishConfig.registry: the registry is chosen by the workflow, never by the package (remove it)"
    jq -e '.private != true' "$manifest" >/dev/null || err "$manifest is marked \"private\": true (npm refuses to publish it)"
    finish
    log "manifest ok: $MF_NAME@$MF_VERSION from tag ${REF_NAME:-}"
    ;;

  scan-tarball)
    dir="$(package_dir)"
    [[ -f $dir/package.json ]] || die "package-dir '$dir' has no package.json"
    packlog="$(mktemp)"
    trap 'rm -f "$packlog"' EXIT
    # --ignore-scripts: the build already ran as its own step; no lifecycle script of the package runs here.
    listing="$(cd "$dir" && npm pack --dry-run --json --ignore-scripts 2>"$packlog")" || {
      cat "$packlog" >&2
      die "npm pack --dry-run failed in '$dir'"
    }
    mapfile -t files < <(jq -r '.[0].files[]?.path' <<<"$listing")
    ((${#files[@]} > 0)) || die "npm pack lists no files for '$dir': an empty package is not published (a scan of nothing proves nothing)"
    # Findings name file and line, never the matched text (an account id is not printed back into the log).
    ca_re='codeartifact\.[a-z0-9-]+\.amazonaws\.com'
    acct_re='(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)'
    for f in "${files[@]}"; do
      path="$dir/$f"
      [[ -f $path ]] || continue
      while IFS=: read -r n _; do err "tarball file '$f' line $n holds a CodeArtifact URL"; done \
        < <(LC_ALL=C grep -anE "$ca_re" -- "$path" || true)
      while IFS=: read -r n _; do err "tarball file '$f' line $n holds a 12-digit number that may be a cloud account id"; done \
        < <(LC_ALL=C grep -anE "$acct_re" -- "$path" || true)
    done
    finish
    log "tarball scan ok: ${#files[@]} file(s), no registry URL, no account id"
    ;;

  token)
    require_env INPUT_CODEARTIFACT_DOMAIN INPUT_CODEARTIFACT_DOMAIN_OWNER INPUT_CODEARTIFACT_REPOSITORY INPUT_AWS_REGION GITHUB_OUTPUT
    raw="$(aws_ca get-authorization-token --duration-seconds 900 --output json)" ||
      die "could not get a CodeArtifact authorization token (is the role allowed codeartifact:GetAuthorizationToken and sts:GetServiceBearerToken?)"
    token="$(jq -r '.authorizationToken // empty' <<<"$raw")" || die "get-authorization-token did not return JSON"
    raw=""
    [[ -n $token ]] || die "get-authorization-token returned no token"
    mask "$token" # BEFORE the first use of the value
    raw="$(aws_ca get-repository-endpoint --repository "$(val codeartifact-repository)" --format npm --output json)" ||
      die "could not read the repository endpoint"
    endpoint="$(jq -r '.repositoryEndpoint // empty' <<<"$raw")"
    # Only a CodeArtifact npm endpoint of the expected shape is ever handed to npm.
    [[ $endpoint =~ ^https://[a-z0-9-]+-[0-9]{12}\.d\.codeartifact\.[a-z0-9-]+\.amazonaws\.com/npm/[A-Za-z0-9._-]+/$ ]] ||
      die "the repository endpoint is not a CodeArtifact npm endpoint (value not shown)"
    {
      printf 'token=%s\n' "$token"
      printf 'endpoint=%s\n' "$endpoint"
    } >>"$GITHUB_OUTPUT"
    log "got a CodeArtifact token (900 s) and the npm endpoint of repository '$(val codeartifact-repository)'"
    ;;

  precheck)
    read_manifest
    rc=0
    describe_version >/dev/null || rc=$?
    if ((rc == 0)); then
      die "$MF_NAME@$MF_VERSION already exists in repository '$(val codeartifact-repository)': a published version is immutable; bump the version and tag again"
    fi
    log "$MF_NAME@$MF_VERSION does not exist yet: it can be published"
    ;;

  publish)
    require_env CODEARTIFACT_AUTH_TOKEN CODEARTIFACT_ENDPOINT
    read_manifest
    dir="$(package_dir)"
    scope="$(val package-scope)"
    host_path="${CODEARTIFACT_ENDPOINT#https:}" # //host/npm/repo/
    # This job holds the token, so it re-checks the version instead of trusting check-manifest. npm refuses to publish a pre-release
    # without an explicit dist-tag, and "latest" must never point at one: a -dev.N goes under "dev". A stable version gets no --tag.
    tag_args=()
    if [[ $MF_VERSION =~ $DEV_RE ]]; then
      tag_args=(--tag dev)
    elif [[ ! $MF_VERSION =~ $STABLE_RE ]]; then
      die "package.json version '$MF_VERSION' must be X.Y.Z or X.Y.Z-dev.N: nothing was published"
    fi
    npmrc="$(mktemp)"
    trap 'rm -f "$npmrc"' EXIT
    # The file holds a REFERENCE to the variable, never the token: npm expands ${CODEARTIFACT_AUTH_TOKEN} itself.
    # shellcheck disable=SC2016
    printf '%s:_authToken=${CODEARTIFACT_AUTH_TOKEN}\n' "$host_path" >"$npmrc"
    # The registry goes on the command line (highest precedence) for the default AND the scope: a project .npmrc with
    # `@scope:registry=` would otherwise win over --registry for a scoped package.
    (cd "$dir" && npm publish --ignore-scripts --userconfig "$npmrc" --registry "$CODEARTIFACT_ENDPOINT" \
      "--${scope}:registry=${CODEARTIFACT_ENDPOINT}" "${tag_args[@]}") || die "npm publish failed for $MF_NAME@$MF_VERSION"
    log "published $MF_NAME@$MF_VERSION"
    ;;

  verify)
    read_manifest
    rc=0
    json="$(describe_version)" || rc=$?
    ((rc != 3)) || die "$MF_NAME@$MF_VERSION was not found in repository '$(val codeartifact-repository)' after publishing"
    ((rc == 0)) || exit "$rc"
    status="$(jq -r '.packageVersion.status // empty' <<<"$json")"
    [[ $status == Published ]] || die "$MF_NAME@$MF_VERSION has status '${status:-unknown}' in the repository (expected Published)"
    summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
    {
      echo "### Package published"
      echo ""
      echo "| | |"
      echo "|---|---|"
      echo "| Package | \`$MF_NAME\` |"
      echo "| Version | \`$MF_VERSION\` |"
      echo "| Tag | \`${REF_NAME:-}\` |"
      echo "| Repository | \`$(val codeartifact-repository)\` |"
      echo "| Region | \`$(val aws-region)\` |"
      echo "| Status | $status |"
    } >>"$summary"
    log "verified: $MF_NAME@$MF_VERSION is $status"
    ;;

  *) die "package-publish: unknown subcommand '$cmd'" ;;
esac
