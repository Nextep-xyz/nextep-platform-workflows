#!/usr/bin/env bats
# Every gate is verified IN RED: each test builds a broken tree under a temporary GATES_ROOT, runs the real gate
# against it and checks that it fails AND names the culprit file. The real tree is never touched.

load 'helpers'

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/.github/workflows" "$FX/.github/actions/validate-inputs" "$FX/contracts" "$FX/docs/parity" "$FX/scripts"
  export GATES_ROOT="$FX"
  WF="$FX/.github/workflows/lego-aws-bad.yml"
}

# red <gate file> <expected fragment>: runs one gate file against $FX and expects failure naming the fragment.
red() {
  run bats "$REPO_ROOT/test/gates/$1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$2"* ]] || { echo "expected '$2' in:"; echo "$output"; return 1; }
}

good_workflow() {
  cat >"$WF" <<'YAML'
name: bad
on:
  workflow_call:
    inputs:
      project: { type: string, required: true }
jobs:
  quality-and-security-gate:
    name: quality-and-security-gate
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - run: echo ok
YAML
}

@test "every workflow-driven gate fails with '0 subjects' when no lego-aws workflow exists" {
  local g
  for g in permissions.bats deploy-lock.bats runner.bats dora-telemetry.bats contract-sync.bats rollback-and-event-guards.bats; do
    run bats "$REPO_ROOT/test/gates/$g"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0 subjects discovered"* ]] || { echo "$g: $output"; return 1; }
  done
}

@test "G2 red: workflow-level permissions, a job without permissions and id-token in the gate job" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
permissions: { contents: read }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { id-token: write }
    steps: [{ run: echo ok }]
  other:
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
YAML
  red permissions.bats "lego-aws-bad.yml: workflow-level 'permissions:' is forbidden"
  [[ "$output" == *"job 'other' does not declare 'permissions:'"* ]]
  [[ "$output" == *"job 'quality-and-security-gate' has 'id-token: write'"* ]]
}

@test "G3 red: a tag-pinned action and a mutable internal reference are named" {
  cat >"$FX/.github/workflows/ci.yml" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: example-org/nextep-platform-workflows/.github/actions/x@v1
YAML
  red pinned-actions.bats "ci.yml: 'actions/checkout@v4' is not pinned"
  [[ "$output" == *"internal reference"* ]]
}

@test "G5 red: an inputs expression inside run: is named" {
  cat >"$FX/.github/workflows/ci.yml" <<'YAML'
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ inputs.cmd }}"
YAML
  red no-interpolation-in-run.bats "ci.yml: run: step #1 interpolates an expression"
}

@test "G9 red: the TLS bypass is named in the script that has it" {
  printf '#!/usr/bin/env bash\nexport NODE_%s=0\n' "TLS_REJECT_UNAUTHORIZED" >"$FX/scripts/bad.sh"
  red no-tls-bypass.bats "scripts/bad.sh: mentions NODE_TLS_REJECT_UNAUTHORIZED"
}

@test "G16 red: a deploy job that cancels in progress is named" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    concurrency: { group: "deploy-lock-x-y", cancel-in-progress: true }
    steps: [{ run: echo ok }]
YAML
  red deploy-lock.bats "lego-aws-bad.yml: job 'deploy': group 'deploy-lock-x-y' must set cancel-in-progress: false"
}

@test "G23 red: a self-hosted job and a runner input are named" {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      runner: { type: string }
jobs:
  deploy:
    runs-on: self-hosted
    permissions: { contents: read }
    steps: [{ run: echo ok }]
YAML
  printf 'workflow: lego-aws-bad
inputs:
  runner: { type: string }
jobs: []
' >"$FX/contracts/lego-aws-bad.contract.yml"
  red runner.bats "lego-aws-bad.yml: job 'deploy' does not run on ubuntu-latest"
  [[ "$output" == *"input named 'runner'"* ]]
  [[ "$output" == *"contracts/lego-aws-bad.contract.yml: declares an input named 'runner'"* ]]
}

@test "G10 red: an input that skips a scan is named in its contract" {
  printf 'workflow: x\ninputs:\n  skip-tests: { type: boolean }\njobs: []\n' >"$FX/contracts/x.contract.yml"
  red runner.bats "contracts/x.contract.yml: input 'skip-tests' would weaken or skip a gate"
}

@test "G12 red: an input missing from the contract, a job name drift and a contract without workflow" {
  good_workflow
  printf 'workflow: lego-aws-bad\ninputs:\n  project: { type: string, required: true }\n  extra: { type: string, default: "" }\nsecrets: {}\noutputs: {}\njobs: [gate-renamed]\n' >"$FX/contracts/lego-aws-bad.contract.yml"
  printf 'workflow: lego-aws-orphan\ninputs: {}\njobs: []\n' >"$FX/contracts/lego-aws-orphan.contract.yml"
  red contract-sync.bats "lego-aws-bad.yml: input missing in the workflow: extra"
  [[ "$output" == *"job names differ"* ]]
  [[ "$output" == *"lego-aws-orphan.contract.yml: contract without a workflow"* ]]
}

@test "G17 red: an ACTIVE telemetry job is named" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  telemetry-phone-home:
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
YAML
  red dora-telemetry.bats "lego-aws-bad.yml: the telemetry-phone-home job is ACTIVE"
  [[ "$output" == *"no DORA-PLACEHOLDER:BEGIN/END block found"* ]]
}

@test "G17 red: active code inside the markers is named with its line" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
  # DORA-PLACEHOLDER:BEGIN
  # telemetry-phone-home: telemetry-url TELEMETRY_TOKEN
  b: 1
  # DORA-PLACEHOLDER:END
YAML
  red dora-telemetry.bats "lego-aws-bad.yml: line 8: the DORA block must be 100% commented"
}

@test "T9 red: a job without the stamps is named, with what is missing" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  stamped:
    runs-on: ubuntu-latest
    outputs:
      started-at: ${{ steps.stamp-start.outputs.epoch }}
      finished-at: ${{ steps.stamp-end.outputs.epoch }}
    steps:
      - { id: stamp-start, run: echo ok }
      - { id: stamp-end, if: "${{ always() }}", run: echo ok }
  bare:
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
  late-end:
    runs-on: ubuntu-latest
    outputs:
      started-at: ${{ steps.stamp-start.outputs.epoch }}
      finished-at: ${{ steps.stamp-end.outputs.epoch }}
    steps:
      - { id: stamp-start, run: echo ok }
      - { id: stamp-end, run: echo ok }
YAML
  red dora-telemetry.bats "lego-aws-bad.yml: job 'bare' does not expose started-at from the step 'stamp-start'"
  [[ "$output" == *"job 'bare': the first step is not the start stamp"* ]]
  [[ "$output" == *"job 'late-end': the last step is not the end stamp (id: stamp-end) with 'if: always()'"* ]]
  [[ "$output" != *"job 'stamped'"* ]]
}

@test "G18 red: a tag that is not in the matrix and a covered id with an input missing in the contract" {
  printf 'parity:\n  - { id: P-CI-01, flow: cicd, summary: x, status: covered, inputs: [nope] }\n  - { id: P-CI-02, flow: cicd, summary: x, status: discarded }\n' >"$FX/docs/parity/matrix.yml"
  printf 'workflow: lego-aws-cicd\ninputs:\n  project: { type: string }\njobs: []\n' >"$FX/contracts/lego-aws-cicd.contract.yml"
  printf '# parity: P-CI-77\n' >"$FX/scripts/a.sh"
  red parity.bats "docs/parity/matrix.yml: tag '# parity: P-CI-77' in the tree is not in the matrix"
  [[ "$output" == *"P-CI-01: input 'nope' does not exist in contracts/lego-aws-cicd.contract.yml"* ]]
  [[ "$output" == *"P-CI-02: discarded without a reason"* ]]
}

@test "G15 red: a workflow with image-tag whose database-migration has no image-tag condition is named" {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      image-tag: { type: string, default: "" }
jobs:
  database-migration:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps: [{ run: echo ok }]
YAML
  red rollback-and-event-guards.bats "lego-aws-bad.yml: job database-migration has no condition on image-tag"
}

@test "G26 red: a gate job that does not call validate-inputs, and a composite that hides the event" {
  good_workflow
  printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: echo hi\n      env: { X: y }\n' >"$FX/.github/actions/validate-inputs/action.yml"
  red rollback-and-event-guards.bats "lego-aws-bad.yml: job quality-and-security-gate does not call the validate-inputs composite"
  [[ "$output" == *"no run step receives EVENT_NAME and REF_NAME"* ]]
}

@test "exceptions: a gate exception that no longer applies breaks the build, naming the file" {
  printf 'exceptions:\n  - gate: G9\n    file: scripts/old.sh\n    reason: x\n    expires: 2999-01-01\n' >"$FX/docs/exceptions.yml"
  printf '#!/usr/bin/env bash\n# gate-exception: G9\necho clean\n' >"$FX/scripts/old.sh"
  red no-tls-bypass.bats "scripts/old.sh: stale G9 exception"
}

@test "G11 red: an internal reference inside a composite and a @main left in a workflow are named" {
  mkdir -p "$FX/scripts/lib" "$FX/.github/actions/inner"
  cp "$REPO_ROOT/scripts/release.sh" "$FX/scripts/"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$FX/scripts/lib/"
  printf 'runs:\n  using: composite\n  steps:\n    - uses: Nextep-xyz/nextep-platform-workflows/.github/actions/other@main\n' >"$FX/.github/actions/inner/action.yml"
  good_workflow
  red release-pins.bats "actions/inner/action.yml: composite references this repository"
  [[ "$output" == *"actions/inner/action.yml: internal reference left on a mutable ref by release.sh"* ]]
}

@test "G11 red: a tree with no workflow fails with '0 subjects' instead of passing" {
  mkdir -p "$FX/.github/actions/inner"
  printf 'runs:\n  using: composite\n  steps: []\n' >"$FX/.github/actions/inner/action.yml"
  red release-pins.bats "0 subjects discovered"
}

@test "GH5 red: an aws-account-id input and a literal AWS_ACCOUNT_ID are named" {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      aws-account-id: { type: string, required: true }
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    env:
      AWS_ACCOUNT_ID: "not-from-the-role"
    steps: [{ run: echo ok }]
YAML
  red aws-account.bats "lego-aws-bad.yml: input 'aws-account-id' looks like an account id"
  [[ "$output" == *"lego-aws-bad.yml: AWS_ACCOUNT_ID is assigned a literal"* ]]
}
