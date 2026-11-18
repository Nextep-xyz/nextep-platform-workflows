# shellcheck shell=bash
# Shape of the optional registry-login inputs (SPEC.md section 0, "Enmienda Login del registry"), shared by validate-inputs.sh (the gate of
# the workflows) and registry-login.sh (setup-project): one definition, so the two can never disagree. Source it AFTER defining err() and
# val() (both scripts do): problems are reported through err(), never printed here.
# The five inputs go together: all empty = the login is off; one of them set = the other four are required.

REGISTRY_INPUTS=(registry-role-arn codeartifact-domain codeartifact-domain-owner codeartifact-repository registry-scope)

# registry_inputs_given: prints how many of the five inputs carry a value
registry_inputs_given() {
  local n c=0
  for n in "${REGISTRY_INPUTS[@]}"; do [[ -z "$(val "$n")" ]] || c=$((c + 1)); done
  printf '%s' "$c"
}

# registry_check_inputs: all or none, and the shape of each. Values of the role and the account are never echoed back.
registry_check_inputs() {
  local n
  [[ "$(registry_inputs_given)" != 0 ]] || return 0
  for n in "${REGISTRY_INPUTS[@]}"; do
    [[ -n "$(val "$n")" ]] || err "input '$n' is required when any registry input is set (registry-role-arn, codeartifact-domain, codeartifact-domain-owner, codeartifact-repository and registry-scope go together)"
  done
  if [[ -n "$(val registry-role-arn)" && ! "$(val registry-role-arn)" =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]]; then
    err "input 'registry-role-arn' is not an IAM role ARN (value not shown)"
  fi
  if [[ -n "$(val codeartifact-domain)" && ! "$(val codeartifact-domain)" =~ ^[a-z][a-z0-9-]{0,48}[a-z0-9]$ ]]; then
    err "input 'codeartifact-domain' is not a CodeArtifact domain name"
  fi
  if [[ -n "$(val codeartifact-domain-owner)" && ! "$(val codeartifact-domain-owner)" =~ ^[0-9]{12}$ ]]; then
    err "input 'codeartifact-domain-owner' is not a 12-digit account id (value not shown)"
  fi
  if [[ -n "$(val codeartifact-repository)" && ! "$(val codeartifact-repository)" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,99}$ ]]; then
    err "input 'codeartifact-repository' is not a CodeArtifact repository name"
  fi
  if [[ -n "$(val registry-scope)" && ! "$(val registry-scope)" =~ ^@[a-z0-9][a-z0-9._-]*$ ]]; then
    err "input 'registry-scope' must be an npm scope such as @example (got '$(val registry-scope)')"
  fi
}
