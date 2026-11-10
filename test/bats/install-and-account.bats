#!/usr/bin/env bats
# P2 building blocks: install-dirs.sh (two package roots), caller-account.sh (GH5), test-postgres.sh (GH4).

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$FAKE_LOG"
  cd "$BATS_TEST_TMPDIR"
}

mkroot() { mkdir -p "$1" && printf '{}' >"$1/package.json" && : >"$1/$2"; }

@test "install-dirs lockfiles: one lockfile per root, relative to the repository, for the cache key" {
  PACKAGE_MANAGER=pnpm INSTALL_DIRS=app,infra run "$SCRIPTS/install-dirs.sh" lockfiles
  [ "$status" -eq 0 ]
  [ "$output" = $'app/pnpm-lock.yaml\ninfra/pnpm-lock.yaml' ]
  PACKAGE_MANAGER=npm INSTALL_DIRS=. run "$SCRIPTS/install-dirs.sh" lockfiles
  [ "$output" = "package-lock.json" ]
  PACKAGE_MANAGER=pnpm run "$SCRIPTS/install-dirs.sh" lockfiles
  [ "$output" = "pnpm-lock.yaml" ]
}

@test "install-dirs install: runs the immutable install in every root, in order" {
  mkroot app pnpm-lock.yaml
  mkroot infra pnpm-lock.yaml
  cat >pnpm <<'SH'
#!/usr/bin/env bash
echo "pnpm $* in $(basename "$PWD")" >>"$FAKE_LOG"
SH
  chmod +x pnpm
  PATH="$PWD:$PATH" PACKAGE_MANAGER=pnpm INSTALL_DIRS=app,infra run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$FAKE_LOG")" = "pnpm install --frozen-lockfile in app,pnpm install --frozen-lockfile in infra" ]
}

@test "install-dirs install: a root without lockfile or package.json fails naming it, and a hostile path is refused" {
  mkdir -p app && printf '{}' >app/package.json
  PACKAGE_MANAGER=pnpm INSTALL_DIRS=app run "$SCRIPTS/install-dirs.sh" install
  [ "$status" -eq 1 ]
  [[ "$output" == *"'app' has no pnpm-lock.yaml"* ]]
  PACKAGE_MANAGER=pnpm INSTALL_DIRS=nothere run "$SCRIPTS/install-dirs.sh" install
  [[ "$output" == *"'nothere' has no package.json"* ]]
  local d
  for d in ../x /abs "a b" 'a;b' "a/"; do
    PACKAGE_MANAGER=pnpm INSTALL_DIRS="$d" run "$SCRIPTS/install-dirs.sh" lockfiles
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid directory"* ]] || { echo "$d: $output"; return 1; }
  done
}

@test "GH5: caller-account prints the account of the session in GITHUB_OUTPUT format and nothing else" {
  run "$SCRIPTS/caller-account.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "account-id=$(printf '%012d' 7)" ]
  grep -q 'sts get-caller-identity' "$FAKE_LOG"
}

@test "GH5: caller-account refuses an answer that is not a 12-digit account and a failing call" {
  FAKE_ACCOUNT=None run "$SCRIPTS/caller-account.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not return a 12-digit account id"* ]]
  FAKE_STS_FAIL=1 run "$SCRIPTS/caller-account.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read the caller identity"* ]]
}

@test "GH5: the aws-oidc composite exposes the account as an output and never touches the runner env file" {
  run yq -r '.outputs["account-id"].value' "$REPO_ROOT/.github/actions/aws-oidc/action.yml"
  [ "$output" = '${{ steps.account.outputs.account-id }}' ]
}

@test "GH4: test-postgres uses the image it is given (default only when empty) and --stop removes the container" {
  FAKE_LOG="$FAKE_LOG" TEST_PG_IMAGE=postgres:17 TEST_PG_TIMEOUT=2 GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" run "$SCRIPTS/test-postgres.sh"
  [ "$status" -eq 0 ]
  grep -q 'docker run .* postgres:17$' "$FAKE_LOG"
  : >"$FAKE_LOG"
  TEST_PG_IMAGE="" TEST_PG_TIMEOUT=2 GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" run "$SCRIPTS/test-postgres.sh"
  grep -q 'docker run .* postgres:16-alpine$' "$FAKE_LOG"
  : >"$FAKE_LOG"
  run "$SCRIPTS/test-postgres.sh" --stop
  [ "$status" -eq 0 ]
  grep -q 'docker rm --force --volumes lego-test-postgres' "$FAKE_LOG"
}

@test "GH4: --stop never fails the cleanup step, even when docker does" {
  FAKE_DOCKER_RC=1 run "$SCRIPTS/test-postgres.sh" --stop
  [ "$status" -eq 0 ]
}

@test "GH4: the quality-gate composite removes the container with always() and passes the image to the start step" {
  local a="$REPO_ROOT/.github/actions/quality-gate/action.yml"
  run yq -r '.runs.steps[] | select(.name == "Remove the ephemeral Postgres") | .if' "$a"
  [[ "$output" == "always() && "* ]]
  run yq -r '.runs.steps[] | select(.id == "pg") | .env.TEST_PG_IMAGE' "$a"
  [ "$output" = '${{ inputs.test-database-image }}' ]
}
