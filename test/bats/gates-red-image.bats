#!/usr/bin/env bats
# The gates of the image family, verified IN RED (same method as gates-red.bats): each test builds a broken tree under a temporary GATES_ROOT, runs the
# real gate against it and checks that it fails AND names the culprit file. The real tree is never touched.

load 'helpers'

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/.github/workflows" "$FX/.github/actions/image-publish" "$FX/contracts" "$FX/docs/parity" "$FX/scripts" "$FX/test/sandbox/callers"
  export GATES_ROOT="$FX"
  WF="$FX/.github/workflows/lego-aws-image-bad.yml"
}

red() { # red <gate file> <expected fragment>
  run bats "$REPO_ROOT/test/gates/$1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$2"* ]] || { echo "expected '$2' in:"; echo "$output"; return 1; }
}

@test "an image gate fails with '0 subjects' when no lego-aws-image workflow exists" {
  local t
  for t in "GI-F1" "GI-F2" "GI-F3" "GI-F4"; do
    run bats --filter "^$t:" "$REPO_ROOT/test/gates/image-publish-flow.bats"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0 subjects discovered"* ]] || { echo "$t: $output"; return 1; }
  done
}

@test "GI-F1 red: two jobs, needs and if, a cancelling concurrency, extra permissions, a secret and a token input are named" {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      registry-token: { type: string }
    secrets:
      NPM_TOKEN: { required: false }
jobs:
  publish:
    needs: [other]
    if: always()
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write, pull-requests: write }
    concurrency: { group: whatever, cancel-in-progress: true }
    steps: [{ run: echo ok }]
  other:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps: [{ run: echo ok }]
YAML
  red image-publish-flow.bats "lego-aws-image-bad.yml: must have exactly one job, 'publish'"
  [[ "$output" == *"lego-aws-image-bad.yml: job publish must not carry needs: or if:"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: job publish needs an 'image-publish-*' concurrency group with cancel-in-progress: false"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: job publish must hold exactly {contents: read, id-token: write}"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: declares workflow_call secrets"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: has a telemetry, token, password, secret or key input"* ]]
}

@test "GI-F2 red: a wrong order, a step before the validation, a caller command and an inline run are named" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: example-org/nextep-platform-workflows/.github/actions/run-project-command@main
        with: { command: make }
      - uses: example-org/nextep-platform-workflows/.github/actions/aws-oidc@main
      - uses: example-org/nextep-platform-workflows/.github/actions/image-publish@main
        with: { command: validate, inputs-json: "x" }
      - uses: aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd
      - run: echo inline
      - uses: example-org/nextep-platform-workflows/.github/actions/image-publish@main
        with: { command: build, inputs-json: "${{ toJSON(inputs) }}" }
      - uses: example-org/nextep-platform-workflows/.github/actions/image-publish@main
        with: { command: digest, inputs-json: "${{ toJSON(inputs) }}" }
YAML
  red image-publish-flow.bats "lego-aws-image-bad.yml: job publish must run: validate, aws-oidc, ECR login, build, digest"
  [[ "$output" == *"lego-aws-image-bad.yml: step #1 runs before the validation and is not the checkout"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: step #2 runs before the validation and is not the checkout"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: job publish uses a composite that runs a command of the caller or deploys"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: job publish has an inline run: step"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: an image-publish step does not pass inputs-json"* ]]
}

@test "GI-F2 red: a missing step is named with its index" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/image-publish@main
        with: { command: validate, inputs-json: "${{ toJSON(inputs) }}" }
YAML
  red image-publish-flow.bats "lego-aws-image-bad.yml: job publish lacks a step (indexes: validate=0 oidc=-1 ecr-login=-1 build=-1 digest=-1)"
}

@test "GI-F3 red: a latest in the workflow, the composite or the script, a script without ENVIRONMENT=release and an environment input are named" {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      environment: { type: string }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - run: docker tag a b:latest
YAML
  printf 'name: image-publish\nruns:\n  using: composite\n  steps:\n    - run: docker push reg/x:latest\n' >"$FX/.github/actions/image-publish/action.yml"
  printf '#!/usr/bin/env bash\n# a comment about latest is fine\nENVIRONMENT=dev "$here/build-push-image.sh"\nTAG=latest\n' >"$FX/scripts/image-publish.sh"
  red image-publish-flow.bats "lego-aws-image-bad.yml: line 10 mentions 'latest'"
  [[ "$output" == *".github/actions/image-publish/action.yml: line 5 mentions 'latest'"* ]]
  [[ "$output" == *"scripts/image-publish.sh: line 4 mentions 'latest'"* ]]
  [[ "$output" == *"scripts/image-publish.sh: does not build with ENVIRONMENT=release"* ]]
  [[ "$output" == *"lego-aws-image-bad.yml: has an 'environment' input"* ]]
  # the runner label and a comment are NOT hits
  [[ "$output" != *"lego-aws-image-bad.yml: line 7 mentions"* ]]
  [[ "$output" != *"scripts/image-publish.sh: line 2 mentions"* ]]
}

@test "GI-F3 red: a workflow without its composite and its script names both as missing" {
  printf 'on: { workflow_call: {} }\njobs: { publish: { runs-on: ubuntu-latest, permissions: { contents: read, id-token: write }, steps: [{ uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 }] } }\n' >"$WF"
  red image-publish-flow.bats ".github/actions/image-publish/action.yml: does not exist"
  [[ "$output" == *"scripts/image-publish.sh: does not exist"* ]]
}

@test "GI-F4 red: a caller on a branch, with wrong permissions, an unpinned reusable, a literal role and secrets: inherit is named" {
  printf 'on: { workflow_call: {} }\njobs: { publish: { runs-on: ubuntu-latest, permissions: { contents: read, id-token: write }, steps: [{ run: echo }] } }\n' >"$WF"
  cat >"$FX/test/sandbox/callers/image-bad.yml" <<'YAML'
on:
  push:
    branches: [main]
permissions: { id-token: write, contents: write }
jobs:
  p:
    uses: example-org/nextep-platform-workflows/.github/workflows/lego-aws-image-publish.yml@v1
    with:
      role-arn: arn:aws:iam::<ACCOUNT>:role/x
    secrets: inherit
YAML
  red image-publish-flow.bats "test/sandbox/callers/image-bad.yml: a caller of an image workflow must fire only on the push of version tags"
  [[ "$output" == *"image-bad.yml: a caller of an image workflow must grant exactly {id-token: write, contents: read}"* ]]
  [[ "$output" == *"image-bad.yml: the reusable workflow must be pinned by an EXACT tag"* ]]
  [[ "$output" == *"image-bad.yml: role-arn must come from a repository variable"* ]]
  [[ "$output" == *"image-bad.yml: passes secrets to an image workflow"* ]]
}

@test "G2 red: 'publish' with extra permissions in an image workflow is named, and the same job in a deploy-family workflow is refused" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write, pull-requests: write }
    steps: [{ run: echo ok }]
YAML
  cat >"$FX/.github/workflows/lego-aws-other.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps: [{ run: echo ok }]
YAML
  red permissions.bats "lego-aws-image-bad.yml: job 'publish' may hold id-token: write only with exactly {contents: read, id-token: write}"
  [[ "$output" == *"lego-aws-other.yml: job 'publish' has 'id-token: write' but this is not a package workflow (lego-aws-package-*.yml) nor an image workflow (lego-aws-image-*.yml)"* ]]
}

@test "the deploy-family gates (G16, G18, G26) judge a deploy workflow and leave an image workflow alone" {
  cat >"$FX/.github/workflows/lego-aws-bad.yml" <<'YAML'
name: bad
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps: [{ run: echo ok }]
YAML
  cat >"$FX/.github/workflows/lego-aws-image-ok.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps: [{ run: echo ok }]
YAML
  local g
  for g in deploy-lock.bats parity.bats rollback-and-event-guards.bats; do
    run bats "$REPO_ROOT/test/gates/$g"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lego-aws-bad.yml"* ]] || { echo "$g: $output"; return 1; }
    [[ "$output" != *"lego-aws-image-ok.yml"* ]] || { echo "$g judged the image workflow: $output"; return 1; }
  done
  run bats "$REPO_ROOT/test/gates/dora-telemetry.bats"
  [[ "$output" == *"lego-aws-bad.yml: has no 'telemetry-phone-home' job"* ]]
  [[ "$output" != *"lego-aws-image-ok.yml"* ]]
}
