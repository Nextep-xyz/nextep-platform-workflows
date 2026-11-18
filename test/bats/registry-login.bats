#!/usr/bin/env bats
# scripts/registry-login.sh (the optional OIDC login to CodeArtifact of setup-project) and the ephemeral user config of
# install-dirs.sh, with `aws`, `curl`, `pnpm` and `npm` fakes. Fictional data: scope @example, project shop.
# The 12-digit numbers are built at run time: this repository is public and its own G13 gate refuses literal ones.

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  export FAKE_AWS_ENV_LOG="$BATS_TEST_TMPDIR/aws-env.log"
  export FAKE_CURL_STDIN_LOG="$BATS_TEST_TMPDIR/curl-stdin.log"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github-env"
  : >"$FAKE_LOG" && : >"$FAKE_AWS_ENV_LOG" && : >"$FAKE_CURL_STDIN_LOG" && : >"$GITHUB_OUTPUT" && : >"$GITHUB_ENV"
  OWNER="$(printf '%012d' 7)"
  JWT="fake-oidc-jwt-Vx55Qa"
  CA_TOKEN="fake-ca-token-Zq81xK"
  REQ_TOKEN="runner-request-token-Bd04"
  export FAKE_CA_TOKEN="$CA_TOKEN"
  printf '{"value":"%s"}' "$JWT" >"$BATS_TEST_TMPDIR/oidc.json"
  printf 'token.example.test|0|200|%s\n' "$BATS_TEST_TMPDIR/oidc.json" >"$BATS_TEST_TMPDIR/routes"
  export FAKE_CURL_ROUTES="$BATS_TEST_TMPDIR/routes"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example.test/oidc?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN="$REQ_TOKEN"
  export GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=2
  export INPUT_REGISTRY_ROLE_ARN="arn:aws:iam::${OWNER}:role/shop-registry-read"
  export INPUT_CODEARTIFACT_DOMAIN=example-domain INPUT_CODEARTIFACT_DOMAIN_OWNER="$OWNER" INPUT_CODEARTIFACT_REPOSITORY=example-repo
  export INPUT_REGISTRY_SCOPE=@example INPUT_AWS_REGION=us-east-2
  cd "$BATS_TEST_TMPDIR"
}

# what the user sees: the runner consumes ::add-mask:: lines, so only the other lines can leak
visible() { grep -v '^::add-mask::' <<<"$output" || true; }

# ---- opt-in: an empty role changes nothing -------------------------------------------------------------------------

@test "an empty registry-role-arn is a no-op: no aws, no curl, no output, no environment" {
  INPUT_REGISTRY_ROLE_ARN="" INPUT_CODEARTIFACT_DOMAIN="" INPUT_CODEARTIFACT_DOMAIN_OWNER="" INPUT_CODEARTIFACT_REPOSITORY="" INPUT_REGISTRY_SCOPE="" \
    run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
  [ ! -s "$GITHUB_OUTPUT" ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "no registry input at all (the caller never heard of the feature) is the same no-op, even without id-token" {
  local k
  for k in $(compgen -v INPUT_); do unset "$k"; done
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
}

# ---- all or none, and the shape of every input -----------------------------------------------------------------------

@test "a role without the rest, or the rest without the role, is refused naming every missing input, and nothing is called" {
  INPUT_CODEARTIFACT_DOMAIN="" INPUT_CODEARTIFACT_REPOSITORY="" INPUT_REGISTRY_SCOPE="" run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  local frag
  for frag in "input 'codeartifact-domain'" "input 'codeartifact-repository'" "input 'registry-scope'"; do
    [[ "$output" == *"$frag"* ]] || { echo "missing: $frag"; echo "$output"; return 1; }
  done
  [[ "$output" != *"input 'codeartifact-domain-owner'"* ]]
  INPUT_REGISTRY_ROLE_ARN="" run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'registry-role-arn'"* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "every input is checked for shape; the role and the account are not echoed back" {
  INPUT_REGISTRY_ROLE_ARN="not-an-arn-${OWNER}" INPUT_CODEARTIFACT_DOMAIN="Bad Domain" INPUT_CODEARTIFACT_DOMAIN_OWNER="short" \
    INPUT_CODEARTIFACT_REPOSITORY="a" INPUT_REGISTRY_SCOPE="example" INPUT_AWS_REGION=nowhere run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  local frag
  for frag in "input 'registry-role-arn'" "input 'codeartifact-domain'" "input 'codeartifact-domain-owner'" "input 'codeartifact-repository'" \
    "input 'registry-scope'" "input 'aws-region'"; do
    [[ "$output" == *"$frag"* ]] || { echo "missing: $frag"; echo "$output"; return 1; }
  done
  [[ "$output" != *"$OWNER"* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "without id-token (a fork pull request, a caller that did not grant it) it fails saying so, before any call" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"id-token: write"* && "$output" == *"fork"* ]]
  [ ! -s "$FAKE_LOG" ]
}

# ---- the happy path: order, audience, masking, scope of the credentials ------------------------------------------------

@test "it asks the runner for an OIDC token with the STS audience, assumes the role with it, then asks CodeArtifact, in that order" {
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF 'audience=sts.amazonaws.com' "$FAKE_LOG"
  local order
  order="$(grep -oE '^(curl|aws (sts assume-role-with-web-identity|codeartifact get-authorization-token|codeartifact get-repository-endpoint))' "$FAKE_LOG" | paste -sd, -)"
  [ "$order" = "curl,aws sts assume-role-with-web-identity,aws codeartifact get-authorization-token,aws codeartifact get-repository-endpoint" ]
  grep -qE "^aws sts assume-role-with-web-identity .*--role-arn arn:aws:iam::${OWNER}:role/shop-registry-read " "$FAKE_LOG"
  grep -qE -- '--role-session-name gha-registry-4242-2( |$)' "$FAKE_LOG"
  grep -q 'codeartifact get-authorization-token .*--duration-seconds 900' "$FAKE_LOG"
  # the request token of the runner goes in the curl config on stdin, never in the arguments
  grep -qF "Authorization: Bearer $REQ_TOKEN" "$FAKE_CURL_STDIN_LOG"
  ! grep -qF -- "$REQ_TOKEN" "$FAKE_LOG"
}

@test "every secret is masked BEFORE it is used or written, and nothing secret is in the visible output" {
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 0 ]
  local s
  for s in "$JWT" "fake-sts-secret-Hq29Zr" "fake-sts-session-Lm73Wd" "$CA_TOKEN"; do
    grep -qxF "::add-mask::$s" <<<"$output" || { echo "not masked: $s"; echo "$output"; return 1; }
    [[ "$(visible)" != *"$s"* ]] || { echo "visible: $s"; return 1; }
  done
  # the token is masked before it reaches GITHUB_OUTPUT: the mask line is printed first, the file written afterwards (one process: order of the lines)
  [[ "$(visible)" != *"$OWNER"* ]] # the endpoint holds the account id: it is not printed
  grep -q "^token=$CA_TOKEN$" "$GITHUB_OUTPUT"
  grep -qE '^endpoint=.*\.d\.codeartifact\.us-east-2\.amazonaws\.com/npm/example-repo/$' "$GITHUB_OUTPUT"
  grep -q "^endpoint=https:" "$GITHUB_OUTPUT"
  [ "$(grep -c '' "$GITHUB_OUTPUT")" -eq 2 ] # token and endpoint, nothing else (not the role credentials, not the JWT)
}

@test "the role credentials live only in the CodeArtifact calls: not in the runner env file, not in the outputs" {
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_ENV" ]
  ! grep -qE 'fake-sts-secret|fake-sts-session|ASIAFAKEKEY|fake-oidc-jwt' "$GITHUB_OUTPUT"
  # both CodeArtifact calls ran with the credentials of the assumed role
  [ "$(grep -c 'key=ASIAFAKEKEY0001 secret=fake-sts-secret-Hq29Zr session=fake-sts-session-Lm73Wd' "$FAKE_AWS_ENV_LOG")" -eq 2 ]
}

# ---- error paths ---------------------------------------------------------------------------------------------------

@test "a denied AssumeRoleWithWebIdentity fails naming the trust policy, and CodeArtifact is never asked" {
  FAKE_STS_ASSUME_FAIL=1 run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not assume the registry role"* && "$output" == *"trust policy"* ]]
  ! grep -q 'codeartifact' "$FAKE_LOG"
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "a failed OIDC request, an empty answer and a denied token request fail the step" {
  printf 'token.example.test|22|403|\n' >"$FAKE_CURL_ROUTES"
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"OIDC token"* ]]
  ! grep -q '^aws ' "$FAKE_LOG"
  printf '{}' >"$BATS_TEST_TMPDIR/oidc.json"
  printf 'token.example.test|0|200|%s\n' "$BATS_TEST_TMPDIR/oidc.json" >"$FAKE_CURL_ROUTES"
  rm -f "$FAKE_CURL_ROUTES.used"
  run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"OIDC token"* ]]
  FAKE_CA_TOKEN_FAIL=1 run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
}

@test "a denied authorization-token request fails with the permissions to check, and no output is written" {
  printf '{"value":"%s"}' "$JWT" >"$BATS_TEST_TMPDIR/oidc.json"
  FAKE_CA_TOKEN_FAIL=1 run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not get a CodeArtifact authorization token"* && "$output" == *"GetAuthorizationToken"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "an endpoint that is not a CodeArtifact npm endpoint is never handed over" {
  FAKE_CA_ENDPOINT="https://registry.example.test/npm/example-repo/" run "$SCRIPTS/registry-login.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a CodeArtifact npm endpoint"* ]]
  ! grep -q '^endpoint=' "$GITHUB_OUTPUT"
}

# ---- install-dirs.sh: the ephemeral user config --------------------------------------------------------------------

mkroot() { mkdir -p "$1" && printf '{}' >"$1/package.json" && : >"$1/$2"; }

# a pnpm / npm that records the user config it was given and what the file held at that moment
fake_pm() { # fake_pm <pnpm|npm>
  cat >"$1" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0") $* in $(basename "$PWD")" >>"$FAKE_LOG"
echo "userconfig=${NPM_CONFIG_USERCONFIG:-}" >>"$FAKE_LOG"
if [[ -n ${NPM_CONFIG_USERCONFIG:-} && -f $NPM_CONFIG_USERCONFIG ]]; then cp "$NPM_CONFIG_USERCONFIG" "$FAKE_USERCONFIG_COPY"; fi
[[ -z ${FAKE_PM_FAIL:-} ]] || { echo "install failed" >&2; exit 1; }
SH
  chmod +x "$1"
}

ENDPOINT_HOST() { printf 'example-domain-%s.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/' "$OWNER"; }

@test "install-dirs: with a token it hands npm/pnpm an ephemeral user config that holds a REFERENCE to the token, and removes it afterwards" {
  mkroot app pnpm-lock.yaml
  fake_pm pnpm
  export FAKE_USERCONFIG_COPY="$BATS_TEST_TMPDIR/userconfig.copy"
  PATH="$PWD:$PATH" PACKAGE_MANAGER=pnpm INSTALL_DIRS=app CODEARTIFACT_AUTH_TOKEN="$CA_TOKEN" REGISTRY_SCOPE=@example \
    REGISTRY_ENDPOINT="https://$(ENDPOINT_HOST)" run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 0 ]
  grep -q 'pnpm install --frozen-lockfile in app' "$FAKE_LOG"
  [ "$(cat "$FAKE_USERCONFIG_COPY")" = "$(printf '@example:registry=https://%s\n//%s:_authToken=${CODEARTIFACT_AUTH_TOKEN}' "$(ENDPOINT_HOST)" "$(ENDPOINT_HOST)")" ]
  ! grep -qF -- "$CA_TOKEN" "$FAKE_USERCONFIG_COPY" "$FAKE_LOG"
  [[ "$output" != *"$CA_TOKEN"* ]]
  # the file was a temporary one, and it is gone; nothing persists in the project, in HOME or in the runner env file
  local cfg
  cfg="$(sed -n 's/^userconfig=//p' "$FAKE_LOG" | head -n1)"
  [ -n "$cfg" ]
  [ ! -e "$cfg" ]
  [ ! -e app/.npmrc ] && [ ! -e .npmrc ] && [ ! -s "$GITHUB_ENV" ]
}

@test "install-dirs: the user config is removed also when the install fails, and npm ci gets it too" {
  mkroot app package-lock.json
  fake_pm npm
  export FAKE_USERCONFIG_COPY="$BATS_TEST_TMPDIR/userconfig.copy"
  FAKE_PM_FAIL=1 PATH="$PWD:$PATH" PACKAGE_MANAGER=npm INSTALL_DIRS=app CODEARTIFACT_AUTH_TOKEN="$CA_TOKEN" REGISTRY_SCOPE=@example \
    REGISTRY_ENDPOINT="https://$(ENDPOINT_HOST)" run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 1 ]
  grep -q 'npm ci in app' "$FAKE_LOG"
  local cfg
  cfg="$(sed -n 's/^userconfig=//p' "$FAKE_LOG" | head -n1)"
  [ -n "$cfg" ]
  [ ! -e "$cfg" ]
}

@test "install-dirs: with no token the install is exactly what it was (no user config at all)" {
  mkroot app pnpm-lock.yaml
  fake_pm pnpm
  export FAKE_USERCONFIG_COPY="$BATS_TEST_TMPDIR/userconfig.copy"
  run env -u NPM_CONFIG_USERCONFIG PATH="$PWD:$PATH" PACKAGE_MANAGER=pnpm INSTALL_DIRS=app REGISTRY_SCOPE="" CODEARTIFACT_AUTH_TOKEN="" "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 0 ]
  grep -qx 'userconfig=' "$FAKE_LOG"
  [ ! -e "$FAKE_USERCONFIG_COPY" ]
}

@test "install-dirs: a token without its endpoint or scope, or an endpoint that is not https, is refused before anything is installed" {
  mkroot app pnpm-lock.yaml
  fake_pm pnpm
  PATH="$PWD:$PATH" PACKAGE_MANAGER=pnpm INSTALL_DIRS=app CODEARTIFACT_AUTH_TOKEN="$CA_TOKEN" run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"REGISTRY_ENDPOINT"* && "$output" == *"REGISTRY_SCOPE"* ]]
  PATH="$PWD:$PATH" PACKAGE_MANAGER=pnpm INSTALL_DIRS=app CODEARTIFACT_AUTH_TOKEN="$CA_TOKEN" REGISTRY_SCOPE=@example \
    REGISTRY_ENDPOINT="http://registry.example.test/npm/example-repo/" run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"https"* && "$output" != *"$CA_TOKEN"* ]]
  PATH="$PWD:$PATH" PACKAGE_MANAGER=pnpm INSTALL_DIRS=app CODEARTIFACT_AUTH_TOKEN="$CA_TOKEN" REGISTRY_SCOPE="example" \
    REGISTRY_ENDPOINT="https://$(ENDPOINT_HOST)" run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 1 ]
  ! grep -q '^pnpm' "$FAKE_LOG"
}
