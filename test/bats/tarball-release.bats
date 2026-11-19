#!/usr/bin/env bats
# scripts/tarball-release.sh with `gh` and `npm` fakes (test/bats/fakes). Fictional data: scope @example, package shop-lib.
# The 12-digit numbers are built at run time: this repository is public and its own G13 gate refuses literal ones.

load 'helpers'

setup() {
  export PATH="$BATS_TEST_DIRNAME/fakes:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
  export FAKE_GH_RELEASES="$BATS_TEST_TMPDIR/releases"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$FAKE_LOG" && : >"$GITHUB_OUTPUT" && : >"$GITHUB_STEP_SUMMARY" && mkdir -p "$FAKE_GH_RELEASES"
  ACCOUNT="$(printf '%012d' 7)"
  TOKEN="fake-gh-token-Zq81xK"
  cd "$BATS_TEST_TMPDIR"
  mkdir -p pkg/dist
  printf '{"name":"@example/shop-lib","version":"1.2.3","main":"dist/index.js"}\n' >pkg/package.json
  printf 'module.exports = 1;\n' >pkg/dist/index.js
  export PACKAGE_DIR=pkg TAG_PREFIX=shop-lib-v NODE_VERSION=22 REF_TYPE=tag REF_NAME=shop-lib-v1.2.3
  export OUT_DIR="$BATS_TEST_TMPDIR/out"
}

# what the user sees: the runner consumes ::add-mask:: lines, so only the other lines can leak
visible() { grep -v '^::add-mask::' <<<"$output" || true; }

# pack_ok: runs the gate's pack step and loads TARBALL / SHA from its outputs
pack_ok() {
  run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  TARBALL="$(sed -n 's/^tarball=//p' "$GITHUB_OUTPUT")"
  SHA="$(sed -n 's/^sha256=//p' "$GITHUB_OUTPUT")"
}

# release_env: the environment of the release job's steps
release_env() {
  export GH_TOKEN="$TOKEN" GH_REPO=example-org/shop ASSETS_DIR="$OUT_DIR" TARBALL EXPECTED_SHA256="$SHA"
}

# ---- check (gate) ---------------------------------------------------------------------------------------------------------

@test "check: a tag that equals prefix + version passes" {
  run "$SCRIPTS/tarball-release.sh" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"@example/shop-lib@1.2.3"* ]]
}

@test "check: a tag that does not match the package.json version fails naming BOTH values and the expected tag" {
  REF_NAME=shop-lib-v1.2.4 run "$SCRIPTS/tarball-release.sh" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"tag 'shop-lib-v1.2.4'"* && "$output" == *"version '1.2.3'"* && "$output" == *"'shop-lib-v1.2.3'"* ]]
}

@test "check: a tag of another package (other prefix) fails naming the tag, the version and the prefix" {
  REF_NAME=other-lib-v1.2.3 run "$SCRIPTS/tarball-release.sh" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"other-lib-v1.2.3"* && "$output" == *"1.2.3"* && "$output" == *"shop-lib-v"* ]]
}

@test "check: a pre-release version is refused (only X.Y.Z is released)" {
  printf '{"name":"@example/shop-lib","version":"1.2.3-dev.1"}\n' >pkg/package.json
  REF_NAME=shop-lib-v1.2.3-dev.1 run "$SCRIPTS/tarball-release.sh" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"version '1.2.3-dev.1' must be X.Y.Z"* ]]
}

@test "check: a branch or a manual run is not a release; every shape problem is reported at once" {
  REF_TYPE=branch PACKAGE_DIR=../x TAG_PREFIX=lib NODE_VERSION=latest run "$SCRIPTS/tarball-release.sh" check
  [ "$status" -eq 1 ]
  local frag
  for frag in "input 'package-dir'" "input 'tag-prefix'" "input 'node-version'" "version tag only"; do
    [[ "$output" == *"$frag"* ]] || { echo "missing: $frag"; echo "$output"; return 1; }
  done
}

@test "check: a package-dir without package.json fails naming the directory" {
  PACKAGE_DIR=nope run "$SCRIPTS/tarball-release.sh" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"package-dir 'nope' has no package.json"* ]]
}

# ---- pack (gate) ----------------------------------------------------------------------------------------------------------

@test "pack: runs npm pack ONCE, writes the tarball with its .sha256 and exposes tarball, sha256 and dir" {
  pack_ok
  [ "$TARBALL" = "example-shop-lib-1.2.3.tgz" ]
  [ "$(grep -c '^npm pack' "$FAKE_LOG")" -eq 1 ]
  [ -f "$OUT_DIR/$TARBALL" ] && [ -f "$OUT_DIR/$TARBALL.sha256" ]
  [ "$SHA" = "$(sha256sum "$OUT_DIR/$TARBALL" | cut -d' ' -f1)" ]
  (cd "$OUT_DIR" && sha256sum --check --status "$TARBALL.sha256")
  grep -q "^dir=$OUT_DIR\$" "$GITHUB_OUTPUT"
}

@test "pack: a publishConfig in the manifest is rejected, naming the problem" {
  printf '{"name":"@example/shop-lib","version":"1.2.3","publishConfig":{"access":"public"}}\n' >pkg/package.json
  run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"sets publishConfig"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "pack: a 12-digit account id and an ARN with an account are rejected naming file and line, never the value" {
  printf 'const role = "arn:aws:iam::%s:role/x";\nconst n = %s;\n' "$ACCOUNT" "$ACCOUNT" >pkg/dist/index.js
  run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"tarball file 'dist/index.js' line 1 holds an ARN with an account id"* ]]
  [[ "$output" == *"tarball file 'dist/index.js' line 2 holds a 12-digit number"* ]]
  [[ "$output" != *"$ACCOUNT"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "pack: a failing npm pack stops with its log; an output directory that is not empty is refused" {
  FAKE_PACK_FAIL=1 run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm pack failed"* ]]
  mkdir -p "$OUT_DIR" && : >"$OUT_DIR/leftover"
  run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not empty"* ]]
}

@test "pack: more than one tarball in the output is refused" {
  FAKE_PACK_TWICE=1 run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exactly one .tgz"* ]]
}

@test "pack: a package that ships nothing but its manifest is not released" {
  rm -rf pkg/dist
  run "$SCRIPTS/tarball-release.sh" pack
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds no file besides package.json"* ]]
}

# ---- create / verify (release) --------------------------------------------------------------------------------------------

@test "create then verify: the Release gets the tarball and its .sha256 and the re-download matches" {
  pack_ok
  release_env
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$FAKE_GH_RELEASES/shop-lib-v1.2.3/$TARBALL" ] && [ -f "$FAKE_GH_RELEASES/shop-lib-v1.2.3/$TARBALL.sha256" ]
  grep -q '^gh release create shop-lib-v1.2.3 ' "$FAKE_LOG"
  absent '--clobber' "$FAKE_LOG"
  run "$SCRIPTS/tarball-release.sh" verify
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "$SHA" "$GITHUB_STEP_SUMMARY"
}

@test "create: a Release that already exists is refused and nothing is overwritten (no --clobber)" {
  pack_ok
  release_env
  mkdir -p "$FAKE_GH_RELEASES/shop-lib-v1.2.3" && echo "published" >"$FAKE_GH_RELEASES/shop-lib-v1.2.3/marker"
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"Release 'shop-lib-v1.2.3' already exists"* ]]
  absent '^gh release create' "$FAKE_LOG"
  [ "$(cat "$FAKE_GH_RELEASES/shop-lib-v1.2.3/marker")" = "published" ]
  [ ! -f "$FAKE_GH_RELEASES/shop-lib-v1.2.3/$TARBALL" ]
}

@test "create: an API error that is not 'release not found' is not read as 'does not exist'" {
  pack_ok
  release_env
  FAKE_GH_VIEW_ERROR="HTTP 502: Bad Gateway" run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not tell whether the Release"* ]]
  absent '^gh release create' "$FAKE_LOG"
}

@test "create: a tarball whose sha256 is not the one the gate computed is not released" {
  pack_ok
  release_env
  printf 'x' >>"$OUT_DIR/$TARBALL"
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not the one the gate computed"* ]]
  absent '^gh release create' "$FAKE_LOG"
}

@test "create: a tampered .sha256 file is not released" {
  pack_ok
  release_env
  printf '%064d  %s\n' 0 "$TARBALL" >"$OUT_DIR/$TARBALL.sha256"
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *".sha256 file does not carry the digest"* ]]
  absent '^gh release create' "$FAKE_LOG"
}

@test "create: the release job re-checks the tag, the prefix and that the tarball is that version's" {
  pack_ok
  release_env
  REF_NAME=shop-lib-v1.2.4 run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not the tarball of version 1.2.4"* ]]
  REF_NAME=other-lib-v1.2.3 run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not 'shop-lib-vX.Y.Z'"* ]]
  REF_TYPE=branch run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"version tag only"* ]]
  absent '^gh release create' "$FAKE_LOG"
}

@test "verify: assets altered after the upload are detected by the sha256 comparison" {
  pack_ok
  release_env
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 0 ]
  FAKE_GH_TAMPER=1 run "$SCRIPTS/tarball-release.sh" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not hold the reviewed bytes"* ]]
  [[ "$output" == *"$SHA"* ]]
}

@test "verify: a Release that lost an asset fails" {
  pack_ok
  release_env
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 0 ]
  rm "$FAKE_GH_RELEASES/shop-lib-v1.2.3/$TARBALL.sha256"
  run "$SCRIPTS/tarball-release.sh" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not carry both"* ]]
}

@test "the token is masked first, reaches gh only through its environment and appears in no output, no log and no file" {
  pack_ok
  release_env
  local out_all
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 0 ]
  [[ "$(head -n1 <<<"$output")" == "::add-mask::$TOKEN" ]]
  out_all="$output"
  run "$SCRIPTS/tarball-release.sh" verify
  [ "$status" -eq 0 ]
  out_all+=$'\n'"$output"
  [[ "$(visible <<<"$out_all")" != *"$TOKEN"* ]]
  absent "$TOKEN" "$FAKE_LOG"
  grep -q 'auth=present repo=example-org/shop' "$FAKE_LOG"
  absent_r "$TOKEN" "$FAKE_GH_RELEASES" "$OUT_DIR" "$GITHUB_STEP_SUMMARY" "$GITHUB_OUTPUT"
}

@test "the token stays out of the output when the run fails too" {
  pack_ok
  release_env
  mkdir -p "$FAKE_GH_RELEASES/shop-lib-v1.2.3"
  run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  FAKE_GH_VIEW_ERROR="HTTP 502" run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  FAKE_GH_RC=9 run "$SCRIPTS/tarball-release.sh" verify
  [ "$status" -ne 0 ]
  [[ "$(visible)" != *"$TOKEN"* ]]
}

@test "create and verify refuse to run without a token or without the repository" {
  pack_ok
  release_env
  GH_TOKEN="" run "$SCRIPTS/tarball-release.sh" create
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_TOKEN"* ]]
  GH_REPO="" run "$SCRIPTS/tarball-release.sh" verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"GH_REPO"* ]]
}
