#!/usr/bin/env bash
# Optional OIDC login to AWS CodeArtifact, so the gates and the deploys can install private @scope/* packages with no static
# credential (SPEC.md section 0, "Enmienda Login del registry"). It runs inside the setup-project composite, which calls it only
# when `registry-role-arn` is set.
#   registry-login.sh token   OIDC token (audience sts.amazonaws.com) -> assume the READ-ONLY registry role -> CodeArtifact
#                             authorization token (900 s) and npm endpoint, written to GITHUB_OUTPUT as `token` and `endpoint`.
# Everything secret is MASKED before its first use. The role credentials exist only in this process and in the two CodeArtifact
# calls: they never reach the runner env file (gate G4) nor a later step. The token is handed to ONE step (the install) through that step's env:,
# where install-dirs.sh turns it into an ephemeral user config that holds a reference, never the value.
# Inputs arrive as INPUT_<NAME> (dashes -> underscores) through env: registry-role-arn, codeartifact-domain,
# codeartifact-domain-owner, codeartifact-repository, registry-scope, aws-region. All empty = nothing to do.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/registry.sh
source "$here/lib/registry.sh"

cmd="${1:?usage: registry-login.sh token}"

errs=()
err() { errs+=("$*"); }
val() { input_env "$1"; }
finish() { # prints every problem at once, then fails
  local e
  ((${#errs[@]} == 0)) && return 0
  for e in "${errs[@]}"; do printf '::error::%s\n' "$e" >&2; done
  exit 1
}

# ca <subcommand> <args...>: aws codeartifact with the credentials of the assumed role, in THIS call's environment only
ca() {
  AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_SESSION_TOKEN="$st" \
    aws codeartifact "$1" --region "$(val aws-region)" --domain "$(val codeartifact-domain)" \
    --domain-owner "$(val codeartifact-domain-owner)" "${@:2}"
}

case "$cmd" in
  token)
    role="$(val registry-role-arn)"
    if [[ "$(registry_inputs_given)" == 0 ]]; then
      log "no registry role configured: nothing to do"
      exit 0
    fi
    # all or none, and the shape of each (lib/registry.sh, shared with validate-inputs.sh): a half-configured registry is never a silent skip
    registry_check_inputs
    [[ "$(val aws-region)" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]] || err "input 'aws-region' is not a region name (got '$(val aws-region)')"
    finish
    require_env GITHUB_OUTPUT
    [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL:-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-} ]] ||
      die "the job has no id-token: write permission, so the registry role cannot be assumed (a pull request from a fork never gets it; grant 'id-token: write' to the caller)"

    # (1) the OIDC token of this job, for STS. The request token of the runner travels in the curl config on stdin, never in the arguments.
    resp="$(mktemp)"
    trap 'rm -f "$resp"' EXIT
    printf 'header = "Authorization: Bearer %s"\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" |
      curl --silent --show-error --fail --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 2 -K - \
        -H 'Accept: application/json' --output "$resp" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" >/dev/null 2>&1 ||
      die "could not get the OIDC token of the job (the runner's token endpoint did not answer)"
    jwt="$(jq -r '.value // empty' "$resp" 2>/dev/null || true)"
    rm -f "$resp"
    [[ -n $jwt ]] || die "the OIDC token request returned no token"
    mask "$jwt" # BEFORE the first use of the value

    # (2) assume the READ-ONLY registry role. Its credentials stay in variables of this process (ak, sk, st) and in the env of the
    # CodeArtifact calls below; nothing is exported and nothing is written to the runner env file.
    creds="$(aws sts assume-role-with-web-identity --role-arn "$role" --role-session-name "gha-registry-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}" \
      --web-identity-token "$jwt" --duration-seconds 900 --output json)" ||
      die "could not assume the registry role (does its trust policy allow this repository and this workflow? job_workflow_ref and sub)"
    jwt=""
    ak="$(jq -r '.Credentials.AccessKeyId // empty' <<<"$creds")"
    sk="$(jq -r '.Credentials.SecretAccessKey // empty' <<<"$creds")"
    st="$(jq -r '.Credentials.SessionToken // empty' <<<"$creds")"
    creds=""
    [[ -n $ak && -n $sk && -n $st ]] || die "assume-role-with-web-identity returned no credentials"
    mask "$sk"
    mask "$st"

    # (3) the CodeArtifact token and the endpoint, with the role credentials
    raw="$(ca get-authorization-token --duration-seconds 900 --output json)" ||
      die "could not get a CodeArtifact authorization token (does the registry role allow codeartifact:GetAuthorizationToken and sts:GetServiceBearerToken?)"
    token="$(jq -r '.authorizationToken // empty' <<<"$raw")" || die "get-authorization-token did not return JSON"
    raw=""
    [[ -n $token ]] || die "get-authorization-token returned no token"
    mask "$token" # BEFORE it is written anywhere
    raw="$(ca get-repository-endpoint --repository "$(val codeartifact-repository)" --format npm --output json)" ||
      die "could not read the repository endpoint (does the registry role allow codeartifact:GetRepositoryEndpoint?)"
    endpoint="$(jq -r '.repositoryEndpoint // empty' <<<"$raw")"
    ak="" sk="" st=""
    # Only a CodeArtifact npm endpoint of the expected shape is ever handed to npm.
    [[ $endpoint =~ ^https://[a-z0-9-]+-[0-9]{12}\.d\.codeartifact\.[a-z0-9-]+\.amazonaws\.com/npm/[A-Za-z0-9._-]+/$ ]] ||
      die "the repository endpoint is not a CodeArtifact npm endpoint (value not shown)"
    {
      printf 'token=%s\n' "$token"
      printf 'endpoint=%s\n' "$endpoint"
    } >>"$GITHUB_OUTPUT"
    log "got a CodeArtifact token (900 s) and the npm endpoint of repository '$(val codeartifact-repository)' for scope $(val registry-scope)"
    ;;

  *) die "registry-login: unknown subcommand '$cmd'" ;;
esac
