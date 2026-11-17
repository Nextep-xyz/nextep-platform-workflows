#!/usr/bin/env bats
# scripts/package-publish.sh with `aws` and `npm` fakes (test/bats/fakes). Fictional data: scope @example, project shop.
# The 12-digit numbers are built at run time: this repository is public and its own G13 gate refuses literal ones.

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  export FAKE_CA_STATE="$BATS_TEST_TMPDIR/published.marker"
  export FAKE_NPMRC_COPY="$BATS_TEST_TMPDIR/npmrc.copy"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github-env"
  : >"$FAKE_LOG" && : >"$GITHUB_OUTPUT" && : >"$GITHUB_STEP_SUMMARY" && : >"$GITHUB_ENV"
  OWNER="$(printf '%012d' 7)"
  TOKEN="fake-ca-token-Zq81xK"
  export FAKE_CA_TOKEN="$TOKEN"
  cd "$BATS_TEST_TMPDIR"
  mkdir -p pkg/dist
  printf '{"name":"@example/shop-lib","version":"1.2.3","main":"dist/index.js"}\n' >pkg/package.json
  printf 'module.exports = 1;\n' >pkg/dist/index.js
  export INPUT_PROJECT=shop INPUT_PACKAGE_DIR=pkg INPUT_PACKAGE_SCOPE=@example INPUT_TAG_PREFIX=shop-lib-v
  export INPUT_ROLE_ARN="arn:aws:iam::${OWNER}:role/shop-lib-publish"
  export INPUT_CODEARTIFACT_DOMAIN=example-domain INPUT_CODEARTIFACT_DOMAIN_OWNER="$OWNER" INPUT_CODEARTIFACT_REPOSITORY=example-repo
  export INPUT_AWS_REGION=us-east-2 INPUT_PACKAGE_MANAGER=pnpm INPUT_NODE_VERSION=22 INPUT_INSTALL_DIRS=. INPUT_TEST_COMMAND="make test-ci"
  export REF_TYPE=tag REF_NAME=shop-lib-v1.2.3
}

# what the user sees: the runner consumes ::add-mask:: lines, so only the other lines can leak
visible() { grep -v '^::add-mask::' <<<"$output" || true; }

# ---- validate -------------------------------------------------------------------------------------------------------

@test "validate: valid inputs on a tag pass" {
  run "$SCRIPTS/package-publish.sh" validate
  [ "$status" -eq 0 ]
}

@test "validate: every problem is reported at once, and the role and the account are not echoed back" {
  INPUT_PROJECT=Shop INPUT_PACKAGE_SCOPE=example INPUT_TAG_PREFIX=lib INPUT_ROLE_ARN="not-an-arn-${OWNER}" \
    INPUT_CODEARTIFACT_DOMAIN="" INPUT_CODEARTIFACT_DOMAIN_OWNER="short" INPUT_CODEARTIFACT_REPOSITORY="" \
    INPUT_AWS_REGION=nowhere INPUT_PACKAGE_MANAGER=yarn INPUT_NODE_VERSION=latest INPUT_PACKAGE_DIR=../x \
    run "$SCRIPTS/package-publish.sh" validate
  [ "$status" -eq 1 ]
  local frag
  for frag in "input 'project'" "input 'package-dir'" "input 'package-scope'" "input 'tag-prefix'" "input 'role-arn'" \
    "input 'codeartifact-domain'" "input 'codeartifact-domain-owner'" "input 'codeartifact-repository'" "input 'aws-region'" \
    "input 'package-manager'" "input 'node-version'"; do
    [[ "$output" == *"$frag"* ]] || { echo "missing: $frag"; echo "$output"; return 1; }
  done
  [[ "$output" != *"$OWNER"* ]]
}

@test "validate: an empty test-command is refused (a gate that checks nothing)" {
  INPUT_TEST_COMMAND="" run "$SCRIPTS/package-publish.sh" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'test-command' must not be empty"* ]]
}

@test "validate: the inputs also arrive as one INPUTS_JSON object (how the composites hand them over)" {
  local k
  for k in $(compgen -v INPUT_); do unset "$k"; done
  INPUTS_JSON="$(jq -n --arg o "$OWNER" '{project:"shop","package-dir":"pkg","package-scope":"@example","tag-prefix":"shop-lib-v","role-arn":("arn:aws:iam::"+$o+":role/shop-lib-publish"),"codeartifact-domain":"example-domain","codeartifact-domain-owner":$o,"codeartifact-repository":"example-repo","aws-region":"us-east-2","package-manager":"pnpm","node-version":"22","install-dirs":".","test-command":"make test-ci"}')"     run "$SCRIPTS/package-publish.sh" validate
  [ "$status" -eq 0 ]
}

@test "validate: a branch run is refused (the only trigger is a version tag)" {
  REF_TYPE=branch REF_NAME=main run "$SCRIPTS/package-publish.sh" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"version tag only"* && "$output" == *"branch"* ]]
}

@test "validate: an empty role-arn (an unset repository variable) asks for the variable" {
  INPUT_ROLE_ARN="" run "$SCRIPTS/package-publish.sh" validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"input 'role-arn' is required"* ]]
}

# ---- check-manifest (GR12 and friends) ------------------------------------------------------------------------------

@test "check-manifest: the tag <prefix><version> matching package.json passes" {
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 0 ]
  [[ "$output" == *"@example/shop-lib@1.2.3"* ]]
}

@test "GR12: a tag that differs from the package.json version fails naming BOTH values, before anything is published" {
  REF_NAME=shop-lib-v1.2.4 run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"shop-lib-v1.2.4"* && "$output" == *"1.2.3"* ]]
  [ ! -s "$FAKE_LOG" ] # no aws, no npm call
}

@test "GR12: a tag with another prefix fails too" {
  REF_NAME=other-v1.2.3 run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"other-v1.2.3"* && "$output" == *"shop-lib-v1.2.3"* ]]
}

@test "check-manifest: a package outside the scope of package-scope is refused" {
  printf '{"name":"@internal/shop-lib","version":"1.2.3"}\n' >pkg/package.json
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"'@internal/shop-lib' must be '@example/<name>'"* ]]
  printf '{"name":"shop-lib","version":"1.2.3"}\n' >pkg/package.json
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
}

@test "check-manifest: publishConfig.registry is rejected (the workflow chooses the registry)" {
  printf '{"name":"@example/shop-lib","version":"1.2.3","publishConfig":{"registry":"https://registry.example.test/"}}\n' >pkg/package.json
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"pkg/package.json sets publishConfig.registry"* ]]
}

@test "check-manifest: publishConfig without a registry is fine; a private package, a pre-release version and a missing name are refused" {
  printf '{"name":"@example/shop-lib","version":"1.2.3","publishConfig":{"access":"restricted"}}\n' >pkg/package.json
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 0 ]
  printf '{"name":"@example/shop-lib","version":"1.2.3","private":true}\n' >pkg/package.json
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"\"private\": true"* ]]
  printf '{"name":"@example/shop-lib","version":"1.2.3-rc.1"}\n' >pkg/package.json
  REF_NAME=shop-lib-v1.2.3-rc.1 run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be X.Y.Z"* ]]
  printf '{"version":"1.2.3"}\n' >pkg/package.json
  run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no 'name'"* ]]
}

@test "check-manifest: a package-dir without package.json fails naming it" {
  INPUT_PACKAGE_DIR=nothere run "$SCRIPTS/package-publish.sh" check-manifest
  [ "$status" -eq 1 ]
  [[ "$output" == *"package-dir 'nothere' has no package.json"* ]]
}

# ---- scan-tarball ---------------------------------------------------------------------------------------------------

@test "scan-tarball: a clean package passes and npm runs without lifecycle scripts" {
  run "$SCRIPTS/package-publish.sh" scan-tarball
  [ "$status" -eq 0 ]
  [[ "$output" == *"tarball scan ok"* ]]
  grep -q 'npm pack --dry-run --json --ignore-scripts' "$FAKE_LOG"
}

@test "scan-tarball: a CodeArtifact URL in a shipped file is refused naming file and line, without printing it" {
  printf 'ok\nconst r = "https://example-domain-%s.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/";\n' "$OWNER" >pkg/dist/config.js
  run "$SCRIPTS/package-publish.sh" scan-tarball
  [ "$status" -eq 1 ]
  [[ "$output" == *"tarball file 'dist/config.js' line 2 holds a CodeArtifact URL"* ]]
  [[ "$output" != *"codeartifact.us-east-2"* && "$output" != *"$OWNER"* ]]
}

@test "scan-tarball: a 12-digit number is refused naming file and line, without printing it; shorter and longer runs are not" {
  printf 'const a = "arn:aws:iam::%s:role/x";\n' "$OWNER" >pkg/dist/arn.js
  printf 'const n = %s;\nconst m = %s;\n' "$(printf '%011d' 5)" "$(printf '%013d' 5)" >pkg/dist/numbers.js
  run "$SCRIPTS/package-publish.sh" scan-tarball
  [ "$status" -eq 1 ]
  [[ "$output" == *"tarball file 'dist/arn.js' line 1 holds a 12-digit number"* ]]
  [[ "$output" != *"numbers.js"* ]]
  [[ "$output" != *"$OWNER"* ]]
}

@test "scan-tarball: a package that lists no files, a failing npm pack and a missing package.json are refused instead of passing" {
  FAKE_PACK_EMPTY=1 run "$SCRIPTS/package-publish.sh" scan-tarball
  [ "$status" -eq 1 ]
  [[ "$output" == *"lists no files"* ]]
  FAKE_PACK_FAIL=1 run "$SCRIPTS/package-publish.sh" scan-tarball
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm pack --dry-run failed"* ]]
  INPUT_PACKAGE_DIR=nothere run "$SCRIPTS/package-publish.sh" scan-tarball
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no package.json"* ]]
}

# ---- token ----------------------------------------------------------------------------------------------------------

@test "token: the token is masked BEFORE it is written anywhere and never appears in the visible output" {
  run "$SCRIPTS/package-publish.sh" token
  [ "$status" -eq 0 ]
  [[ "$(head -n1 <<<"$output")" == "::add-mask::$TOKEN" ]]
  [[ "$(visible)" != *"$TOKEN"* ]]
  [[ "$(visible)" != *"$OWNER"* ]] # the endpoint holds the account id: it is not printed either
  grep -q "^token=$TOKEN$" "$GITHUB_OUTPUT"
  grep -q '^endpoint=.*.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/$' "$GITHUB_OUTPUT"
  [ ! -s "$GITHUB_ENV" ] # never in the runner env file
  grep -q 'codeartifact get-authorization-token .*--duration-seconds 900' "$FAKE_LOG"
}

@test "token: an endpoint that is not a CodeArtifact npm endpoint is never handed over" {
  FAKE_CA_ENDPOINT="https://registry.example.test/npm/example-repo/" run "$SCRIPTS/package-publish.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a CodeArtifact npm endpoint"* ]]
  ! grep -q '^endpoint=' "$GITHUB_OUTPUT"
}

@test "token: a denied token request fails with the permissions to check" {
  FAKE_CA_TOKEN_FAIL=1 run "$SCRIPTS/package-publish.sh" token
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not get a CodeArtifact authorization token"* ]]
}

# ---- precheck -------------------------------------------------------------------------------------------------------

@test "precheck: a version that already exists fails, naming it, and npm is never called" {
  FAKE_CA_EXISTS=1 run "$SCRIPTS/package-publish.sh" precheck
  [ "$status" -eq 1 ]
  [[ "$output" == *"@example/shop-lib@1.2.3 already exists"* ]]
  ! grep -q '^npm ' "$FAKE_LOG"
  grep -q -- '--namespace example --package shop-lib --package-version 1.2.3' "$FAKE_LOG"
}

@test "precheck: a version that does not exist passes" {
  run "$SCRIPTS/package-publish.sh" precheck
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist yet"* ]]
}

@test "precheck: any error other than 'not found' fails closed" {
  FAKE_CA_DESCRIBE_FAIL=1 run "$SCRIPTS/package-publish.sh" precheck
  [ "$status" -eq 1 ]
  [[ "$output" == *"describe-package-version failed"* && "$output" == *"nothing was published"* ]]
}

# ---- publish --------------------------------------------------------------------------------------------------------

@test "publish: the token is only in the environment; the npmrc holds a reference, the registry is forced for the scope and scripts are off" {
  CODEARTIFACT_AUTH_TOKEN="$TOKEN" CODEARTIFACT_ENDPOINT="https://example-domain-${OWNER}.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/" \
    run "$SCRIPTS/package-publish.sh" publish
  [ "$status" -eq 0 ]
  [[ "$output" != *"$TOKEN"* ]]
  grep -qF -- '--ignore-scripts' "$FAKE_LOG"
  grep -qF -- "--registry https://example-domain-${OWNER}.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/" "$FAKE_LOG"
  grep -qF -- "--@example:registry=https://example-domain-${OWNER}.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/" "$FAKE_LOG"
  ! grep -qF -- "$TOKEN" "$FAKE_LOG" # not an argument either (it would show in the process list)
  # the userconfig npm saw: a reference to the variable, never the value
  [ "$(cat "$FAKE_NPMRC_COPY")" = "//example-domain-${OWNER}.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/:_authToken=\${CODEARTIFACT_AUTH_TOKEN}" ]
  # nothing persists: no .npmrc in the package, nothing in the runner env file
  [ ! -e pkg/.npmrc ] && [ ! -e .npmrc ]
  [ ! -s "$GITHUB_ENV" ]
}

@test "publish: without the token or the endpoint it refuses to start" {
  run "$SCRIPTS/package-publish.sh" publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"CODEARTIFACT_AUTH_TOKEN"* ]]
}

@test "publish: a failing npm publish fails the step" {
  FAKE_NPM_PUBLISH_FAIL=1 CODEARTIFACT_AUTH_TOKEN="$TOKEN" CODEARTIFACT_ENDPOINT="https://example-domain-${OWNER}.d.codeartifact.us-east-2.amazonaws.com/npm/example-repo/" \
    run "$SCRIPTS/package-publish.sh" publish
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm publish failed for @example/shop-lib@1.2.3"* ]]
  [[ "$output" != *"$TOKEN"* ]]
}

# ---- verify and the whole flow --------------------------------------------------------------------------------------

@test "verify: a published version passes and the summary holds no secret, endpoint or account" {
  : >"$FAKE_CA_STATE"
  run "$SCRIPTS/package-publish.sh" verify
  [ "$status" -eq 0 ]
  grep -q '@example/shop-lib' "$GITHUB_STEP_SUMMARY"
  grep -q '1.2.3' "$GITHUB_STEP_SUMMARY"
  ! grep -qE "$OWNER|$TOKEN|codeartifact\.|https://" "$GITHUB_STEP_SUMMARY"
}

@test "verify: a version that is not Published, or not found, fails" {
  FAKE_CA_EXISTS=1 FAKE_CA_STATUS=Unfinished run "$SCRIPTS/package-publish.sh" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"status 'Unfinished'"* ]]
  run "$SCRIPTS/package-publish.sh" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"was not found in repository"* ]]
}

@test "the whole flow in order: validate, manifest, scan, token, precheck, publish, verify; a second run stops at the precheck" {
  local s
  for s in validate check-manifest scan-tarball; do
    run "$SCRIPTS/package-publish.sh" "$s"
    [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
  done
  run "$SCRIPTS/package-publish.sh" token
  [ "$status" -eq 0 ]
  export CODEARTIFACT_AUTH_TOKEN CODEARTIFACT_ENDPOINT
  CODEARTIFACT_AUTH_TOKEN="$(sed -n 's/^token=//p' "$GITHUB_OUTPUT")"
  CODEARTIFACT_ENDPOINT="$(sed -n 's/^endpoint=//p' "$GITHUB_OUTPUT")"
  run "$SCRIPTS/package-publish.sh" precheck
  [ "$status" -eq 0 ]
  run "$SCRIPTS/package-publish.sh" publish
  [ "$status" -eq 0 ]
  run "$SCRIPTS/package-publish.sh" verify
  [ "$status" -eq 0 ]
  [ "$(grep -c '^npm publish' "$FAKE_LOG")" -eq 1 ]
  # re-running the same tag: the version now exists, so it fails before npm is called again
  run "$SCRIPTS/package-publish.sh" precheck
  [ "$status" -eq 1 ]
  [ "$(grep -c '^npm publish' "$FAKE_LOG")" -eq 1 ]
}
