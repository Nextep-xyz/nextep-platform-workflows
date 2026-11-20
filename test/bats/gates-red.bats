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
  for g in permissions.bats deploy-lock.bats runner.bats dora-telemetry.bats contract-sync.bats rollback-and-event-guards.bats no-static-registry-token.bats package-publish-flow.bats cloud-free.bats; do
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

@test "G27 red: a DOCKER_CONTEXT in a script and an undeclared AWS_ variable are named in their files, and a stale allowlist entry is named" {
  printf '#!/usr/bin/env bash\nexport DOCKER_%s=.\n' "CONTEXT" >"$FX/scripts/bad.sh"
  red tool-env-namespaces.bats "scripts/bad.sh: names DOCKER_CONTEXT"
  rm "$FX/scripts/bad.sh"
  printf '#!/usr/bin/env bash\necho "$AWS_%s"\n' "NEW_THING" >"$FX/scripts/undeclared.sh"
  export TOOL_ENV_ALLOWLIST="$BATS_TEST_TMPDIR/allow.txt"
  printf 'AWS_OLD  # gone\n' >"$TOOL_ENV_ALLOWLIST"
  red tool-env-namespaces.bats "scripts/undeclared.sh: names AWS_NEW_THING"
  red tool-env-namespaces.bats "stale entry AWS_OLD"
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

@test "G17 red: a workflow without the telemetry job, or with a marker left, is named" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{ run: echo ok }]
  # DORA-PLACEHOLDER:BEGIN
  # telemetry-phone-home:
  # DORA-PLACEHOLDER:END
YAML
  red dora-telemetry.bats "lego-aws-bad.yml: has no 'telemetry-phone-home' job"
  [[ "$output" == *"lego-aws-bad.yml: a DORA-PLACEHOLDER marker is left"* ]]
}

# a workflow with a telemetry job that breaks every rule of G17 at once
bad_telemetry_workflow() {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      run-deploy: { type: boolean, default: true }
    secrets:
      TELEMETRY_TOKEN: { required: false }
jobs:
  quality-and-security-gate:
    name: quality-and-security-gate
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps: [{ run: echo ok }]
  deploy:
    name: deploy
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps: [{ run: echo ok }]
  telemetry-phone-home:
    name: telemetry-phone-home
    needs: [quality-and-security-gate]
    if: ${{ inputs.telemetry-url != '' }}
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions: { contents: read, id-token: write, pull-requests: write }
    environment: prod
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: example-org/nextep-platform-workflows/.github/actions/aws-oidc@main
      - run: echo hi
YAML
}

@test "G17 red: every broken rule of the telemetry job is named (needs, if, continue-on-error, timeout, permissions, inputs, secret)" {
  bad_telemetry_workflow
  red dora-telemetry.bats "lego-aws-bad.yml: 'telemetry-phone-home' must need EVERY other job"
  [[ "$output" == *"the 'if' of 'telemetry-phone-home' must contain always()"* ]]
  [[ "$output" == *"the 'if' of 'telemetry-phone-home' must be off when telemetry-audience is empty"* ]]
  [[ "$output" == *"the 'if' of 'telemetry-phone-home' must require inputs.run-deploy"* ]]
  [[ "$output" == *"must set continue-on-error: true at job level"* ]]
  [[ "$output" == *"must set timeout-minutes <= 5"* ]]
  [[ "$output" == *"permissions must be exactly {contents: read, id-token: write}"* ]]
  [[ "$output" == *"input telemetry-url must exist"* ]]
  [[ "$output" == *"input telemetry-audience must exist"* ]]
  [[ "$output" == *"a TELEMETRY secret is declared"* ]]
}

@test "T8 red: a checkout, a cloud role, a run step and an environment in the telemetry job are named" {
  bad_telemetry_workflow
  red dora-telemetry.bats "lego-aws-bad.yml: 'telemetry-phone-home' must have exactly one step"
  [[ "$output" == *"has a 'run:' step"* ]]
  [[ "$output" == *"may only use the internal telemetry composite"* ]]
  [[ "$output" == *"checks out code or assumes a cloud role"* ]]
  [[ "$output" == *"declares an environment"* ]]
  [[ "$output" == *"the step of 'telemetry-phone-home' must set continue-on-error: true"* ]]
}

@test "G2 red: the telemetry job holding id-token with extra permissions is named" {
  bad_telemetry_workflow
  red permissions.bats "job 'telemetry-phone-home' may hold id-token: write only with exactly {contents: read, id-token: write}"
}

@test "T0 red: a shared secret or an HMAC in a script is named with its line" {
  cat >"$FX/scripts/send.sh" <<'SH'
#!/usr/bin/env bash
sig="$(openssl dgst -sha256 -hmac "$TELEMETRY_TOKEN" payload.json)"
SH
  red dora-telemetry.bats "scripts/send.sh: line 2: a shared secret or an HMAC signature"
}

@test "T3 red: the actor in a telemetry script or composite is named; a comment saying 'no actor' is not" {
  mkdir -p "$FX/.github/actions/telemetry"
  printf '%s\n' '#!/usr/bin/env bash' '# there is no actor in the payload' 'echo "$GITHUB_ACTOR"' >"$FX/scripts/telemetry-build.sh"
  printf 'runs:\n  using: composite\n  steps: []\n' >"$FX/.github/actions/telemetry/action.yml"
  red dora-telemetry.bats "scripts/telemetry-build.sh: line 3: refers to the actor"
  [[ "$output" != *"scripts/telemetry-build.sh: line 2:"* ]]
}

@test "T13 red: a caller without id-token and the absence of a reporting caller are named" {
  mkdir -p "$FX/test/sandbox/callers"
  printf 'name: c\non: push\npermissions: { contents: read }\njobs:\n  j:\n    uses: example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@main\n    with: { project: shop }\n' >"$FX/test/sandbox/callers/plain.yml"
  red dora-telemetry.bats "test/sandbox/callers/plain.yml: the caller does not grant id-token: write"
  [[ "$output" == *"no sandbox caller reports telemetry"* ]]
  printf 'name: c\non: push\npermissions: { id-token: write }\njobs:\n  j:\n    uses: example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@main\n    with:\n      telemetry-url: https://collector.example.com\n      telemetry-audience: literal-audience\n' >"$FX/test/sandbox/callers/literal.yml"
  red dora-telemetry.bats "test/sandbox/callers/literal.yml: telemetry-url must come from a repository variable"
  [[ "$output" == *"telemetry-audience must come from a repository variable"* ]]
  [[ "$output" == *"must pin the workflow by tag"* ]]
}

@test "G17 red: a contract without the telemetry inputs or job, or that still declares a secret, is named" {
  printf 'workflow: lego-aws-bad\ninputs:\n  project: { type: string }\nsecrets:\n  TELEMETRY_TOKEN: { required: false }\njobs:\n  - deploy\n' >"$FX/contracts/lego-aws-bad.contract.yml"
  red dora-telemetry.bats "lego-aws-bad.contract.yml: telemetry-url and telemetry-audience must be listed as inputs"
  [[ "$output" == *"the job 'telemetry-phone-home' is not listed"* ]]
  [[ "$output" == *"declares secrets: the telemetry has none (OIDC)"* ]]
}

@test "G-COE red: a job-level continue-on-error on a non-telemetry job is named, on the telemetry job it is not" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  deploy:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps: [{ run: echo ok }]
  telemetry-phone-home:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps: [{ run: echo ok }]
YAML
  red fail-hard.bats "lego-aws-bad.yml: job 'deploy' sets continue-on-error: true"
  [[ "$output" != *"job 'telemetry-phone-home' sets continue-on-error"* ]]
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

@test "G-PY4 red: a setup-project step without the Python inputs, a composite that installs Python unconditionally and an unpinned setup-python are named" {
  mkdir -p "$FX/.github/actions/setup-project"
  cat >"$WF" <<'YAML'
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
      - name: Set up the project
        uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
        with:
          install-dirs: .
YAML
  cat >"$FX/.github/actions/setup-project/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - uses: actions/setup-python@v5
      with: { python-version: "3.12" }
    - shell: bash
      run: scripts/python-install.sh
YAML
  red python-toolchain.bats "lego-aws-bad.yml: job 'quality-and-security-gate', step 'Set up the project': python-version is not passed from the workflow input"
  [[ "$output" == *"lego-aws-bad.yml: the workflow does not declare the inputs python-version and python-requirements"* ]]
  [[ "$output" == *"setup-project/action.yml: the composite does not declare python-version and python-requirements"* ]]
  [[ "$output" == *"setup-project/action.yml: the actions/setup-python step is not conditional on inputs.python-version"* ]]
  [[ "$output" == *"setup-project/action.yml: actions/setup-python must be 'actions/setup-python@<40-hex SHA> # vX.Y.Z'"* ]]
}

@test "G-PY4 red: a tree with no setup-project step or no setup-python reference fails with 'no ... found' instead of passing" {
  good_workflow
  red python-toolchain.bats "no setup-project step found in any reusable workflow"
  [[ "$output" == *"no actions/setup-python reference found"* ]]
}

# A workflow shaped like environment-deploy whose database stage ignores `migrate`. The prefix inputs.migrate-before-deploy
# must NOT count as honouring inputs.migrate (the first condition below is the trap).
db_stage_workflow() {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      migrate-before-deploy: { type: boolean, default: false }
      migrate: { type: boolean, default: true }
jobs:
  infra-deploy:
    name: infra-deploy
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - name: tunnel
        if: ${{ inputs.compute != 'static' && inputs.migrate-before-deploy }}
        uses: example-org/nextep-platform-workflows/.github/actions/ssm-tunnel@main
      - name: migrate
        if: ${{ inputs.compute != 'static' && inputs.migrate && inputs.migrate-before-deploy }}
        uses: example-org/nextep-platform-workflows/.github/actions/migrate@main
      - name: post
        if: ${{ inputs.migrate-before-deploy || inputs.compute == 'static' }}
        uses: example-org/nextep-platform-workflows/.github/actions/post-deploy@main
  database-migration:
    name: database-migration
    runs-on: ubuntu-latest
    permissions: { contents: read }
    if: ${{ inputs.compute != 'static' && !inputs.migrate-before-deploy }}
    steps: [{ run: echo ok }]
  post-deploy:
    name: post-deploy
    runs-on: ubuntu-latest
    permissions: { contents: read }
    if: ${{ inputs.compute != 'static' && inputs.migrate }}
    steps: [{ run: echo ok }]
YAML
}

@test "G-DB2 red: each piece of the database stage that ignores inputs.migrate is named (inputs.migrate-before-deploy does not count)" {
  db_stage_workflow
  red skip-database-stage.bats "lego-aws-bad.yml: job database-migration does not honour inputs.migrate"
  [[ "$output" == *"lego-aws-bad.yml: a tunnel/migrate step of infra-deploy does not honour inputs.migrate"* ]]
  [[ "$output" == *"lego-aws-bad.yml: the post-deploy step of infra-deploy does not run when the stage is off"* ]]
  [[ "$output" != *"job post-deploy (the one that waits"* ]]
}

@test "G-DB2/G-DB3 red: a workflow with migrate-before-deploy but no migrate input, and a tree with no such workflow, are named" {
  db_stage_workflow
  sed -i '/^      migrate: {/d' "$WF"
  red skip-database-stage.bats "lego-aws-bad.yml: the workflow has migrate-before-deploy but no migrate input"
  [[ "$output" == *"lego-aws-bad.yml: input migrate must be type boolean with default true"* ]]
  rm -f "$WF"
  good_workflow
  red skip-database-stage.bats "no workflow with the migrate-before-deploy input was found"
}

# ---- package family (lego-aws-package-*) -------------------------------------------------------------------------------------------

@test "G2 red: 'publish' with id-token outside a package workflow, and in a package workflow with extra permissions, are named" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps: [{ run: echo ok }]
YAML
  cat >"$FX/.github/workflows/lego-aws-package-bad.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write, pull-requests: write }
    steps: [{ run: echo ok }]
YAML
  red permissions.bats "lego-aws-bad.yml: job 'publish' has 'id-token: write' but this is not a package workflow"
  [[ "$output" == *"lego-aws-package-bad.yml: job 'publish' may hold id-token: write only with exactly {contents: read, id-token: write}"* ]]
}

@test "deploy-family gates (G16, G17, T9, G18, G26, G-PY4) still judge lego-aws-bad.yml and leave a package workflow alone" {
  good_workflow
  cat >"$FX/.github/workflows/lego-aws-package-ok.yml" <<'YAML'
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
    [[ "$output" != *"lego-aws-package-ok.yml"* ]] || { echo "$g judged the package workflow: $output"; return 1; }
  done
  run bats "$REPO_ROOT/test/gates/dora-telemetry.bats"
  [[ "$output" == *"lego-aws-bad.yml: has no 'telemetry-phone-home' job"* ]]
  [[ "$output" != *"lego-aws-package-ok.yml"* ]]
}

@test "GR15 red: a secret, a token input, a token in another env, a literal _authToken, an unmasked token and a publish with scripts on are named" {
  mkdir -p "$FX/test/sandbox/callers" "$FX/.github/actions/other"
  cat >"$FX/.github/workflows/lego-aws-package-bad.yml" <<'YAML'
on:
  workflow_call:
    secrets:
      NPM_TOKEN: { required: true }
    inputs:
      npm-token: { type: string, default: "" }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - run: echo ok
        env: { TOKEN: "${{ secrets.NPM_TOKEN }}" }
YAML
  printf 'workflow: lego-aws-package-bad\ninputs:\n  registry-password: { type: string }\nsecrets:\n  NPM_TOKEN: { required: true }\n' >"$FX/contracts/lego-aws-package-bad.contract.yml"
  cat >"$FX/test/sandbox/callers/package.yml" <<'YAML'
on: { push: { tags: ["v*"] } }
jobs:
  p:
    uses: example-org/nextep-platform-workflows/.github/workflows/lego-aws-package-bad.yml@v1
    secrets: inherit
YAML
  cat >"$FX/.github/actions/other/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: echo ok
      env: { NODE_AUTH_TOKEN: abc }
YAML
  cat >"$FX/scripts/package-bad.sh" <<'SH'
#!/usr/bin/env bash
token="$(aws codeartifact get-authorization-token --output json)"
echo "token=$token" >>"$GITHUB_OUTPUT"
printf '//host/:_authToken=%s\n' "$token" >"$HOME/.npmrc"
npm publish --registry x
SH
  red no-static-registry-token.bats "contracts/lego-aws-package-bad.contract.yml: declares secrets"
  [[ "$output" == *"lego-aws-package-bad.contract.yml: input 'registry-password' looks like a credential"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: declares workflow_call secrets"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: input 'npm-token' looks like a credential"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: line "*"reads the secrets context"* ]]
  [[ "$output" == *"callers/package.yml: a caller of a package workflow passes secrets"* ]]
  [[ "$output" == *".github/actions/other/action.yml: env 'NODE_AUTH_TOKEN' carries a registry token"* ]]
  [[ "$output" == *"scripts/package-bad.sh: line 4 writes an _authToken that is not a \${VAR} reference"* ]]
  [[ "$output" == *"scripts/package-bad.sh: line 4 persists registry configuration"* ]]
  [[ "$output" == *"scripts/package-bad.sh: writes to GITHUB_OUTPUT (line 3) before masking"* || "$output" == *"scripts/package-bad.sh: asks for an authorization token but never masks it"* ]]
  [[ "$output" == *"scripts/package-bad.sh: line 5: npm publish without --ignore-scripts"* ]]
}

@test "GR15 red: a token written to GITHUB_OUTPUT before it is masked is named with both lines" {
  cat >"$FX/scripts/package-bad.sh" <<'SH'
#!/usr/bin/env bash
token="$(aws codeartifact get-authorization-token --output json)"
echo "token=$token" >>"$GITHUB_OUTPUT"
mask "$token"
npm publish --ignore-scripts --registry x
SH
  red no-static-registry-token.bats "scripts/package-bad.sh: writes to GITHUB_OUTPUT (line 3) before masking the token (line 4)"
}

# A package workflow that breaks every flow rule of package-publish-flow.bats at once.
bad_package_workflow() {
  cat >"$FX/.github/workflows/lego-aws-package-bad.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/aws-oidc@main
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
  publish:
    needs: [quality-and-security-gate]
    if: always()
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
      - uses: example-org/nextep-platform-workflows/.github/actions/aws-oidc@main
      - id: registry
        uses: example-org/nextep-platform-workflows/.github/actions/package-registry@main
        with: { command: token }
      - uses: example-org/nextep-platform-workflows/.github/actions/run-project-command@main
        with: { label: build, command: make }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-registry@main
        with: { command: precheck, x: "${{ steps.registry.outputs.token }}" }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-publish@main
        with: { auth-token: "${{ steps.registry.outputs.token }}x" }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-publish@main
        with: { auth-token: "${{ steps.registry.outputs.token }}" }
YAML
}

@test "GR12 / GR-F1 / GR-F2 / GR-F3 red: each broken rule of a package workflow is named" {
  bad_package_workflow
  red package-publish-flow.bats "lego-aws-package-bad.yml: job 'quality-and-security-gate' does not validate the inputs and the tag trigger"
  [[ "$output" == *"lego-aws-package-bad.yml: job 'publish' does not validate the inputs and the tag trigger"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: job quality-and-security-gate uses aws-oidc, package-registry or package-publish"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: job quality-and-security-gate holds id-token"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: job publish must not carry an if:"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: job publish lacks a step"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: the package-publish composite must be used exactly once (found 2)"* ]]
  [[ "$output" == *"lego-aws-package-bad.yml: the token output of step 'registry' is also passed to"* ]]
}

@test "GR12 / GR-F2 red: a wrong order (check-manifest after setup, a caller command after the role) is named" {
  cat >"$FX/.github/workflows/lego-aws-package-bad.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/package-check@main
        with: { command: validate }
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
      - uses: example-org/nextep-platform-workflows/.github/actions/package-check@main
        with: { command: check-manifest }
  publish:
    needs: [quality-and-security-gate]
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/package-check@main
        with: { command: validate }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-check@main
        with: { command: check-manifest }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-check@main
        with: { command: scan-tarball }
      - uses: example-org/nextep-platform-workflows/.github/actions/aws-oidc@main
      - uses: example-org/nextep-platform-workflows/.github/actions/run-project-command@main
        with: { label: build, command: make }
      - id: registry
        uses: example-org/nextep-platform-workflows/.github/actions/package-registry@main
        with: { command: token }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-registry@main
        with: { command: precheck }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-publish@main
        with: { auth-token: "${{ steps.registry.outputs.token }}" }
      - uses: example-org/nextep-platform-workflows/.github/actions/package-registry@main
        with: { command: verify }
YAML
  red package-publish-flow.bats "lego-aws-package-bad.yml: job 'quality-and-security-gate': check-manifest (GR12) must run before the project is set up"
  [[ "$output" == *"lego-aws-package-bad.yml: job publish runs a caller command (step #4) after assuming the role"* ]]
}

@test "GR-F4 red: a publish job that cancels, and a caller that fires on a branch, a pull request, without tag pin or with wide permissions, are named" {
  mkdir -p "$FX/test/sandbox/callers"
  cat >"$FX/.github/workflows/lego-aws-package-bad.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    concurrency: { group: "x", cancel-in-progress: true }
    steps: [{ run: echo ok }]
YAML
  cat >"$FX/test/sandbox/callers/package.yml" <<'YAML'
on:
  push: { branches: [main] }
  pull_request: {}
permissions: write-all
jobs:
  p:
    uses: example-org/nextep-platform-workflows/.github/workflows/lego-aws-package-bad.yml@main
YAML
  red package-publish-flow.bats "lego-aws-package-bad.yml: job publish needs a 'package-publish-*' concurrency group with cancel-in-progress: false"
  [[ "$output" == *"callers/package.yml: a caller of a package workflow must fire only on the push of version tags"* ]]
  [[ "$output" == *"callers/package.yml: a caller of a package workflow must grant exactly {id-token: write, contents: read}"* ]]
  [[ "$output" == *"callers/package.yml: the reusable workflow must be pinned by tag"* ]]
}

# ---- registry login (GL1-GL3, GR15 amendment) -----------------------------------------------------------------------------------

@test "GL1-GL3 red: a tree with no composite or script of the registry login fails with '0 subjects' or 'no ... found' instead of passing" {
  mkdir -p "$FX/.github/actions/unrelated"
  printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: echo ok\n' >"$FX/.github/actions/unrelated/action.yml"
  red registry-login.bats "no composite runs registry-login.sh (a gate that finds nothing proves nothing)"
  [[ "$output" == *"GL2: 0 subjects discovered"* ]]
  [[ "$output" == *"GL3: 0 subjects discovered"* ]]
}

@test "GL1 red: the login in another composite, a required or defaulted input, no condition, outputs and a continue-on-error are named" {
  mkdir -p "$FX/.github/actions/setup-project" "$FX/.github/actions/other"
  cat >"$FX/.github/actions/other/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: scripts/registry-login.sh token
YAML
  cat >"$FX/.github/actions/setup-project/action.yml" <<'YAML'
inputs:
  registry-role-arn: { required: true }
  codeartifact-domain: { default: "x" }
  codeartifact-domain-owner: { default: "" }
  codeartifact-repository: { default: "" }
  registry-scope: { default: "" }
outputs:
  token: { value: "${{ steps.registry.outputs.token }}" }
runs:
  using: composite
  steps:
    - id: registry
      continue-on-error: true
      shell: bash
      run: scripts/registry-login.sh token
YAML
  red registry-login.bats ".github/actions/other/action.yml: runs registry-login.sh: the login lives only in setup-project"
  [[ "$output" == *".github/actions/setup-project/action.yml: input 'registry-role-arn' must exist, be optional and default to empty"* ]]
  [[ "$output" == *".github/actions/setup-project/action.yml: input 'codeartifact-domain' must exist, be optional and default to empty"* ]]
  [[ "$output" == *".github/actions/setup-project/action.yml: input 'aws-region' must exist, be optional and default to empty"* ]]
  [[ "$output" == *".github/actions/setup-project/action.yml: the step that runs registry-login.sh must carry exactly 'if: inputs.registry-role-arn"* ]]
  [[ "$output" == *".github/actions/setup-project/action.yml: the login step needs an id and no continue-on-error"* ]]
  [[ "$output" == *".github/actions/setup-project/action.yml: the composite declares outputs: the registry token must not leave it"* ]]
}

@test "GL2 red: a second reader of the token, a reader that is not the install and an install without the env are named" {
  mkdir -p "$FX/.github/actions/setup-project"
  cat >"$FX/.github/actions/setup-project/action.yml" <<'YAML'
inputs: {}
runs:
  using: composite
  steps:
    - id: registry
      if: inputs.registry-role-arn != ''
      shell: bash
      run: scripts/registry-login.sh token
    - name: leak
      shell: bash
      run: echo "${{ steps.registry.outputs.token }}"
    - name: Immutable install
      shell: bash
      run: scripts/install-dirs.sh install
YAML
  red registry-login.bats "setup-project/action.yml: the token output is read by a step that does not run the immutable install"
  [[ "$output" == *"setup-project/action.yml: the install step must receive the token as env CODEARTIFACT_AUTH_TOKEN"* ]]
}

@test "GL2 red: two steps reading the token are named with the count" {
  mkdir -p "$FX/.github/actions/setup-project"
  cat >"$FX/.github/actions/setup-project/action.yml" <<'YAML'
inputs: {}
runs:
  using: composite
  steps:
    - id: registry
      if: inputs.registry-role-arn != ''
      shell: bash
      run: scripts/registry-login.sh token
    - name: Immutable install
      shell: bash
      env: { CODEARTIFACT_AUTH_TOKEN: "${{ steps.registry.outputs.token }}" }
      run: scripts/install-dirs.sh install
    - name: second reader
      shell: bash
      env: { T: "${{ steps.registry.outputs.token }}" }
      run: scripts/install-dirs.sh install
YAML
  red registry-login.bats "setup-project/action.yml: the token output (steps.registry.outputs.token) must be read by exactly one step (found 2)"
}

@test "GL3 red: an unmasked token, a write to GITHUB_ENV, a persisted npmrc, a literal _authToken and exported AWS credentials are named with their line" {
  cat >"$FX/scripts/registry-login.sh" <<'SH'
#!/usr/bin/env bash
token="$(aws codeartifact get-authorization-token --output json)"
echo "token=$token" >>"$GITHUB_OUTPUT"
mask "$token"
echo "AWS_SECRET_ACCESS_KEY=$sk" >>"$GITHUB_ENV"
export AWS_SESSION_TOKEN="$st"
npm config set //host/:_authToken abc
SH
  cat >"$FX/scripts/install-dirs.sh" <<'SH'
#!/usr/bin/env bash
printf '//host/:_authToken=%s\n' "$CODEARTIFACT_AUTH_TOKEN" >"$HOME/.npmrc"
SH
  red registry-login.bats "scripts/registry-login.sh: line 5 writes to or reads \$GITHUB_ENV"
  [[ "$output" == *"scripts/registry-login.sh: line 7 persists registry configuration"* ]]
  [[ "$output" == *"scripts/registry-login.sh: line 6 exports AWS credentials"* ]]
  [[ "$output" == *"scripts/registry-login.sh: never masks \$jwt"* ]]
  [[ "$output" == *"scripts/registry-login.sh: masks \$token (line 4) after writing to GITHUB_OUTPUT (line 3)"* ]]
  [[ "$output" == *"scripts/install-dirs.sh: line 2 persists registry configuration"* ]]
  [[ "$output" == *"scripts/install-dirs.sh: line 2 writes an _authToken that is not a \${VAR} reference"* ]]
  [[ "$output" == *"scripts/install-dirs.sh: the user config is not a mktemp file"* ]]
  [[ "$output" == *"scripts/install-dirs.sh: no trap removes the temporary user config"* ]]
}

@test "G2 (login amendment): a gate job with exact permissions, no deploy role and registry-role-arn in setup-project passes; every deviation is named" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read, pull-requests: write, id-token: write }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
        with: { registry-role-arn: "${{ inputs.registry-role-arn }}" }
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
        with: { registry-role-arn: "${{ inputs.registry-role-arn }}" }
YAML
  run bats "$REPO_ROOT/test/gates/permissions.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # without pull-requests (the environment-deploy gate) it passes too
  sed -i 's/permissions: { contents: read, pull-requests: write, id-token: write }/permissions: { contents: read, id-token: write }/' "$WF"
  run bats "$REPO_ROOT/test/gates/permissions.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # every deviation is named: an extra permission, a deploy role in the gate, a setup-project that ignores the input
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write, id-token: write }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/aws-oidc@main
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
YAML
  red permissions.bats "lego-aws-bad.yml: job 'quality-and-security-gate' has 'id-token: write' but its permissions are not exactly {contents: read, pull-requests: write (optional), id-token: write}"
  [[ "$output" == *"lego-aws-bad.yml: job 'quality-and-security-gate' has 'id-token: write' but uses a composite that assumes a deploy role or deploys"* ]]
  [[ "$output" == *"lego-aws-bad.yml: job 'quality-and-security-gate' has 'id-token: write' but its setup-project step does not take registry-role-arn from the workflow input"* ]]
}

@test "G2 red (login amendment): the gate of a package workflow with id-token, and a gate with no setup-project step at all, are named" {
  cat >"$FX/.github/workflows/lego-aws-package-bad.yml" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps: [{ run: echo ok }]
YAML
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read, id-token: write }
    steps: [{ run: echo ok }]
YAML
  red permissions.bats "lego-aws-package-bad.yml: job 'quality-and-security-gate' has 'id-token: write' but the gate of a package workflow holds no cloud credentials"
  [[ "$output" == *"lego-aws-bad.yml: job 'quality-and-security-gate' has 'id-token: write' but its setup-project step does not take registry-role-arn from the workflow input"* ]]
}

@test "GL4 red: a workflow without the inputs, a setup-project that forgets one, and a job that passes the role without id-token are named" {
  cat >"$WF" <<'YAML'
on:
  workflow_call:
    inputs:
      registry-role-arn: { type: string, required: true }
      aws-region: { type: string, default: "us-east-2" }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps:
      - uses: example-org/nextep-platform-workflows/.github/actions/setup-project@main
        with:
          registry-role-arn: "${{ inputs.registry-role-arn }}"
YAML
  red registry-login.bats "lego-aws-bad.yml: input 'registry-role-arn' must be a string, optional and empty by default"
  [[ "$output" == *"lego-aws-bad.yml: input 'codeartifact-domain' must be a string, optional and empty by default"* ]]
  [[ "$output" == *"lego-aws-bad.yml: a setup-project call does not pass registry-scope: \${{ inputs.registry-scope }}"* ]]
  [[ "$output" == *"lego-aws-bad.yml: a setup-project call does not pass aws-region: \${{ inputs.aws-region }}"* ]]
  [[ "$output" == *"lego-aws-bad.yml: job 'quality-and-security-gate' passes registry-role-arn to setup-project but does not hold id-token: write"* ]]
}

@test "GL4 red: a deploy workflow with no setup-project call fails instead of passing" {
  cat >"$WF" <<'YAML'
on: { workflow_call: {} }
jobs:
  quality-and-security-gate:
    runs-on: ubuntu-latest
    permissions: { contents: read }
    steps: [{ run: echo ok }]
YAML
  red registry-login.bats "lego-aws-bad.yml: no setup-project call was found"
}

@test "GR15 red (login amendment): the token in the setup-project env from anything but the login step, or in a second step, is named" {
  mkdir -p "$FX/.github/actions/setup-project"
  cat >"$FX/.github/actions/setup-project/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: echo one
      env: { CODEARTIFACT_AUTH_TOKEN: "${{ secrets.NPM_TOKEN }}" }
YAML
  red no-static-registry-token.bats ".github/actions/setup-project/action.yml: env 'CODEARTIFACT_AUTH_TOKEN' carries a registry token ('\${{ secrets.NPM_TOKEN }}')"
  [[ "$output" == *"setup-project/action.yml: must set CODEARTIFACT_AUTH_TOKEN from \${{ steps.registry.outputs.token }} in exactly one step (found 0)"* ]]
}

@test "L1 red: an edited LICENSE, a NOTICE without a copyright line and a missing NOTICE are named; no files at all is '0 subjects'" {
  run bats "$REPO_ROOT/test/gates/license.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"L1: 0 subjects discovered"* ]]

  cp "$REPO_ROOT/LICENSE" "$FX/LICENSE"
  echo "an edit" >>"$FX/LICENSE"
  echo "just a name" >"$FX/NOTICE"
  red license.bats "LICENSE: is not the canonical Apache-2.0 text"
  [[ "$output" == *"NOTICE: must carry a 'Copyright <year> <holder>' line"* ]]

  cp "$REPO_ROOT/LICENSE" "$FX/LICENSE"
  rm "$FX/NOTICE"
  red license.bats "NOTICE: missing from the repository root"
  [[ "$output" != *"LICENSE: is not the canonical"* ]]
}

# ---- the cloud-free family (lego-node-ci, lego-package-release) -----------------------------------------------------------------
# cf_fixture: copies the real files of the family into $FX, so each test breaks ONE thing in a tree that is otherwise the real one.
cf_fixture() {
  rm -rf "$FX/.github/workflows/lego-node-ci.yml" "$FX/.github/workflows/lego-package-release.yml" "$FX/.github/actions/node-ci" \
    "$FX/.github/actions/package-release-check" "$FX/.github/actions/package-release-publish" "$FX/test/sandbox"
  mkdir -p "$FX/test/sandbox/callers" "$FX/.github/actions"
  cp "$REPO_ROOT"/.github/workflows/lego-node-ci.yml "$REPO_ROOT"/.github/workflows/lego-package-release.yml "$FX/.github/workflows/"
  cp "$REPO_ROOT"/contracts/lego-node-ci.contract.yml "$REPO_ROOT"/contracts/lego-package-release.contract.yml "$FX/contracts/"
  cp -r "$REPO_ROOT"/.github/actions/node-ci "$REPO_ROOT"/.github/actions/package-release-check "$REPO_ROOT"/.github/actions/package-release-publish "$REPO_ROOT"/.github/actions/setup-project "$FX/.github/actions/"
  cp "$REPO_ROOT"/scripts/tarball-release.sh "$FX/scripts/"
  cp "$REPO_ROOT"/test/sandbox/callers/node-ci.yml "$REPO_ROOT"/test/sandbox/callers/package-release.yml "$FX/test/sandbox/callers/"
  NODECI="$FX/.github/workflows/lego-node-ci.yml"
  RELEASE="$FX/.github/workflows/lego-package-release.yml"
  PUBLISH="$FX/.github/actions/package-release-publish/action.yml"
  SCRIPT="$FX/scripts/tarball-release.sh"
}

@test "the cloud-free fixture is clean: every cloud-free gate passes on the real files of the family" {
  cf_fixture
  run bats "$REPO_ROOT/test/gates/cloud-free.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "discovery red: G2, G12, G23, G3, G5 and G9 SEE a workflow that is not named lego-aws-* (the gap that made them pass over a broken tree)" {
  cat >"$FX/.github/workflows/lego-node-ci.yml" <<'YAML'
on:
  workflow_call:
    inputs:
      cmd: { type: string }
permissions: { contents: read }
jobs:
  ci:
    runs-on: self-hosted
    permissions: { contents: write, id-token: write }
    steps:
      - uses: actions/checkout@v4
      - run: echo "${{ inputs.cmd }}" && NODE_TLS_REJECT_UNAUTHORIZED=0 true
YAML
  printf 'workflow: lego-aws-other
jobs: []
' >"$FX/contracts/lego-aws-other.contract.yml"   # so that G12 has a contract to discover: it must still name the workflow with none
  red permissions.bats "lego-node-ci.yml: workflow-level 'permissions:' is forbidden"
  [[ "$output" == *"lego-node-ci.yml: job 'ci' has 'id-token: write' but this is a cloud-free workflow"* ]]
  [[ "$output" == *"lego-node-ci.yml: job 'ci' grants write-all/read-all or contents: write"* ]]
  red contract-sync.bats "lego-node-ci.yml: has no contract (contracts/lego-node-ci.contract.yml)"
  red runner.bats "lego-node-ci.yml: job 'ci' does not run on ubuntu-latest"
  red pinned-actions.bats "lego-node-ci.yml: 'actions/checkout@v4' is not pinned"
  red no-interpolation-in-run.bats "lego-node-ci.yml: run: step #1 interpolates an expression"
  red no-tls-bypass.bats "lego-node-ci.yml: mentions NODE_TLS_REJECT_UNAUTHORIZED"
}

@test "G12 red: a cloud-free workflow whose inputs or job names drift from its contract is named" {
  cf_fixture
  yq -i '.on.workflow_call.inputs.surprise = {"type": "string", "default": ""}' "$RELEASE"
  yq -i '.jobs = ["gate", "publish"]' "$FX/contracts/lego-package-release.contract.yml"
  red contract-sync.bats "lego-package-release.yml: input not in the contract: surprise"
  [[ "$output" == *"lego-package-release.yml: job names differ from the contract"* ]]
}

@test "G2 red: contents: write is allowed ONLY to the release job of lego-package-release, and only with exactly that permission" {
  cf_fixture
  yq -i '.jobs.gate.permissions.contents = "write"' "$RELEASE"
  red permissions.bats "lego-package-release.yml: job 'gate' grants write-all/read-all or contents: write"
  [[ "$output" != *"job 'release' grants"* ]]
  cf_fixture
  yq -i '.jobs.release.permissions.packages = "write"' "$RELEASE"
  red permissions.bats "lego-package-release.yml: job 'release' may hold contents: write only with exactly {contents: write}"
  cf_fixture
  yq -i '.jobs.ci.permissions.contents = "write"' "$NODECI"
  red permissions.bats "lego-node-ci.yml: job 'ci' grants write-all/read-all or contents: write"
}

@test "G17 and T13 leave the cloud-free family alone; T13 still judges a caller of an aws workflow" {
  cf_fixture
  run bats "$REPO_ROOT/test/gates/dora-telemetry.bats" --filter "G17: each contract"
  [[ "$output" != *"lego-node-ci.contract.yml"* && "$output" != *"lego-package-release.contract.yml"* ]] || { echo "$output"; return 1; }
  printf 'name: c\non: push\npermissions: { contents: read }\njobs:\n  j:\n    uses: example-org/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@main\n' >"$FX/test/sandbox/callers/aws.yml"
  run bats "$REPO_ROOT/test/gates/dora-telemetry.bats" --filter "T13"
  [[ "$output" == *"test/sandbox/callers/aws.yml: the caller does not grant id-token: write"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"callers/node-ci.yml"* && "$output" != *"callers/package-release.yml"* ]] || { echo "$output"; return 1; }
}

@test "CF-SEC red: another secret, a required secret, the denylist in any other workflow, credential-looking inputs, a secret read twice or elsewhere and a stale entry are named" {
  cf_fixture
  yq -i '.secrets.NPM_TOKEN = {"required": true}' "$FX/contracts/lego-node-ci.contract.yml"
  yq -i '.on.workflow_call.secrets.NPM_TOKEN = {"required": true} | .on.workflow_call.secrets.INTERNAL_DENYLIST.required = true' "$NODECI"
  red cloud-free.bats "contracts/lego-node-ci.contract.yml: declares the secret 'NPM_TOKEN'"
  [[ "$output" == *"contracts/lego-node-ci.contract.yml: secret 'NPM_TOKEN' must be declared with required: false"* ]]
  [[ "$output" == *"lego-node-ci.yml: declares the secret 'NPM_TOKEN'"* ]]
  [[ "$output" == *"lego-node-ci.yml: secret 'NPM_TOKEN' must not be required"* ]]
  [[ "$output" == *"lego-node-ci.yml: secret 'INTERNAL_DENYLIST' must not be required"* ]]

  cf_fixture
  yq -i '.secrets.PUBLISH_PAT = {"required": false} | .inputs.github-token = {"type": "string"}' "$FX/contracts/lego-package-release.contract.yml"
  yq -i '.on.workflow_call.secrets.PUBLISH_PAT.required = false | .on.workflow_call.inputs.auth-token = {"type": "string"}' "$RELEASE"
  red cloud-free.bats "contracts/lego-package-release.contract.yml: declares the secret 'PUBLISH_PAT'"
  [[ "$output" == *"lego-package-release.yml: declares the secret 'PUBLISH_PAT'"* ]]
  [[ "$output" == *"contracts/lego-package-release.contract.yml: input 'github-token' looks like a credential"* ]]
  [[ "$output" == *"lego-package-release.yml: input 'auth-token' looks like a credential"* ]]
  # the denylist, which the release now takes, is judged like in lego-node-ci: never required
  cf_fixture
  yq -i '.on.workflow_call.secrets.INTERNAL_DENYLIST.required = true' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: secret 'INTERNAL_DENYLIST' must not be required"
  # ... and it must reach exactly one place, the env: of the test step of the gate job: not the pack step, not the release job
  cf_fixture
  yq -i '(.jobs.gate.steps[] | select(.id == "pack")).env.Z = "${{ secrets.INTERNAL_DENYLIST }}"' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: secret 'INTERNAL_DENYLIST' is read in more than one place"
  cf_fixture
  yq -i 'del(.jobs.gate.steps[] | select(.name == "Test").env)' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: secret 'INTERNAL_DENYLIST' must reach exactly one place: the env: of the node-ci test step (found 0)"

  cf_fixture
  yq -i '(.jobs.ci.steps[] | select(.name == "Typecheck")).env.X = "${{ secrets.INTERNAL_DENYLIST }}"' "$NODECI"
  red cloud-free.bats "lego-node-ci.yml: secret 'INTERNAL_DENYLIST' is read in more than one place"
  cf_fixture
  yq -i '(.jobs.gate.steps[] | select(.id == "pack")).env.Y = "${{ secrets.PAT }}"' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: line"
  [[ "$output" == *"reads a secret other than the one this workflow may declare"* ]]

  cf_fixture
  yq -i 'del(.secrets.INTERNAL_DENYLIST)' "$FX/contracts/lego-node-ci.contract.yml"
  yq -i 'del(.on.workflow_call.secrets) | del(.jobs.ci.steps[] | select(.name == "Test").env.INTERNAL_DENYLIST)' "$NODECI"
  red cloud-free.bats "contracts/lego-node-ci.contract.yml: is in the CF-SEC allowlist for the secret 'INTERNAL_DENYLIST' but no longer declares it (stale entry"

  cf_fixture
  yq -i 'del(.secrets.INTERNAL_DENYLIST)' "$FX/contracts/lego-package-release.contract.yml"
  yq -i 'del(.on.workflow_call.secrets) | del(.jobs.gate.steps[] | select(.name == "Test").env.INTERNAL_DENYLIST)' "$RELEASE"
  red cloud-free.bats "contracts/lego-package-release.contract.yml: is in the CF-SEC allowlist for the secret 'INTERNAL_DENYLIST' but no longer declares it (stale entry"
}

@test "CF-TOKEN red: the token in a workflow, in a with:, in a run or an argument of the release composite, or in a composite the gate job uses is named" {
  cf_fixture
  yq -i '(.jobs.ci.steps[] | select(.name == "Typecheck")).env.GH_TOKEN = "${{ github.token }}"' "$NODECI"
  red cloud-free.bats "lego-node-ci.yml: mentions the token of the run"
  cf_fixture
  yq -i '(.jobs.release.steps[] | select(.with.command == "create")).with.token = "${{ github.token }}"' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: mentions the token of the run"
  cf_fixture
  sed -i 's/^        set -euo pipefail$/        set -euo pipefail\n        echo "${{ github.token }}"/' "$PUBLISH"
  red cloud-free.bats "package-release-publish/action.yml: the token of the run appears 2 time(s) but only 1 time(s) as the value of an env: entry"
  cf_fixture
  yq -i '(.jobs.gate.steps[] | select(.id == "pack")).uses = "Nextep-xyz/nextep-platform-workflows/.github/actions/package-release-publish@main"' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: job 'gate' uses 'package-release-publish', the composite that holds the token of the release job"
}

@test "CF-REL red: a checkout, a run step and a foreign action in the release job, a wrong needs, no per-tag concurrency, a digest from the artifact, two packs, a loose gate and an unchecked tag are named" {
  cf_fixture
  yq -i '.jobs.release.steps = [{"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"}, {"run": "make release"}, {"uses": "example-org/other@0123456789abcdef0123456789abcdef01234567"}] + .jobs.release.steps | .jobs.release.needs = ["gate", "other"] | del(.jobs.release.concurrency)' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: job release uses 'actions/checkout@"
  [[ "$output" == *"job release has a 'run:' step"* ]]
  [[ "$output" == *"job release uses 'example-org/other@"* ]]
  [[ "$output" == *"job release checks out the repository: it must run no code of the caller's repository"* ]]
  [[ "$output" == *"job release must need exactly the gate job"* ]]
  [[ "$output" == *"job release needs a concurrency group per tag"* ]]

  cf_fixture
  yq -i '(.jobs.release.steps[] | select(.with.command == "create")).with.sha256 = "abc" | .jobs.release.concurrency."cancel-in-progress" = true' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: every publish step of job release must take sha256 from needs.gate.outputs.sha256"
  [[ "$output" == *"job release needs a concurrency group per tag"* ]]

  cf_fixture
  yq -i '.jobs.gate.steps += [.jobs.gate.steps[] | select(.id == "pack")] | .jobs.gate.permissions.actions = "read"' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: job gate must pack exactly once (found 2 'pack' steps)"
  [[ "$output" == *"job gate must hold exactly {contents: read}"* ]]

  cf_fixture
  yq -i 'del(.jobs.gate.steps[] | select(.with.command == "check"))' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: job gate must run the tag/version check before it packs"

  cf_fixture
  yq -i '.jobs.gate.steps[0].with."persist-credentials" = true | .jobs.gate.steps += [{"run": "npm pack"}]' "$RELEASE"
  red cloud-free.bats "lego-package-release.yml: job gate must check out with persist-credentials: false"
  [[ "$output" == *"a run: step packs the package"* ]]
}

@test "CF-REL red: with no job that holds contents: write the gate says so, and a stale entry of its allowlist is named" {
  cf_fixture
  yq -i '.jobs.release.permissions.contents = "read"' "$RELEASE"
  red cloud-free.bats "CF-REL: no cloud-free workflow has a job that holds contents: write"
  cf_fixture
  yq -i 'del(.jobs.release.steps[] | select((.uses // "") | test("download-artifact")))' "$RELEASE"
  red cloud-free.bats "the release allowlist names 'actions/download-artifact@' but no release job uses it (stale entry)"
}

@test "CF-NOREWRITE red: --clobber, a Release created without checking it exists, and the token printed or traced are named" {
  cf_fixture
  sed -i 's/--verify-tag --title/--clobber --verify-tag --title/' "$SCRIPT"
  red cloud-free.bats "scripts/tarball-release.sh: line"
  [[ "$output" == *"rewrites or removes a Release or its assets"* ]]

  cf_fixture
  sed -i 's/^      if gh release view "\$tag".*$/      if false; then/' "$SCRIPT"
  red cloud-free.bats "scripts/tarball-release.sh: must test 'gh release view' BEFORE 'gh release create'"

  cf_fixture
  sed -i 's/^    tag="\$REF_NAME"$/    tag="$REF_NAME"\n    echo "token=$GH_TOKEN"\n    set -x/' "$SCRIPT"
  red cloud-free.bats "scripts/tarball-release.sh: line"
  [[ "$output" == *"uses GH_TOKEN other than in require_env / mask"* ]]
  [[ "$output" == *"prints the environment or traces the shell"* ]]
}

@test "CF-CALLER red: an id-token, @main, wrong permissions, secrets: inherit, pull_request_target, a branch trigger on a release and a workflow nobody calls are named" {
  cf_fixture
  yq -i '.permissions."id-token" = "write" | .jobs.checks.uses = "example-org/nextep-platform-workflows/.github/workflows/lego-node-ci.yml@main" | .jobs.checks.secrets = "inherit" | .on = {"pull_request_target": null, "push": {"branches": ["main"]}}' "$FX/test/sandbox/callers/node-ci.yml"
  red cloud-free.bats "test/sandbox/callers/node-ci.yml: a caller of lego-node-ci grants id-token"
  [[ "$output" == *"the workflow lego-node-ci must be pinned by tag"* ]]
  [[ "$output" == *"a caller must not use pull_request_target"* ]]
  [[ "$output" == *"passes 'secrets: inherit'"* ]]

  cf_fixture
  yq -i '.jobs.checks.secrets = {"NPM_TOKEN": "x"} | .jobs.checks.permissions.contents = "write"' "$FX/test/sandbox/callers/node-ci.yml"
  red cloud-free.bats "passes the secret 'NPM_TOKEN', which lego-node-ci does not declare"
  [[ "$output" == *"job 'checks' calls lego-node-ci and must grant exactly {\"contents\":\"read\"}"* ]]

  cf_fixture
  yq -i '.jobs.release-shop-lib.permissions.contents = "read" | .on.push = {"branches": ["main"]} | .on.workflow_dispatch = null' "$FX/test/sandbox/callers/package-release.yml"
  red cloud-free.bats "job 'release-shop-lib' calls lego-package-release and must grant exactly {\"contents\":\"write\"}"
  [[ "$output" == *"a caller of lego-package-release must fire only on the push of version tags"* ]]

  cf_fixture
  rm "$FX/test/sandbox/callers/package-release.yml"
  red cloud-free.bats "lego-package-release.yml: no sandbox caller in test/sandbox/callers uses it"
}

@test "EXEC red: a script that a composite runs but is not executable, and one that does not exist, are named; no composite at all is '0 subjects'" {
  run bats "$REPO_ROOT/test/gates/script-modes.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"EXEC: 0 subjects discovered"* ]]
  mkdir -p "$FX/.github/actions/demo"
  cat >"$FX/.github/actions/demo/action.yml" <<'YAML'
name: demo
description: demo
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        "$SCRIPTS/loose.sh"
        "$SCRIPTS/missing.sh"
YAML
  printf '#!/usr/bin/env bash\n' >"$FX/scripts/loose.sh"
  chmod 644 "$FX/scripts/loose.sh"
  red script-modes.bats "scripts/loose.sh: is run by .github/actions/demo/action.yml but is not executable"
  [[ "$output" == *"runs scripts/missing.sh, which does not exist"* ]]
}
