#!/usr/bin/env bats
# Tests of the gate framework itself (test/gates/lib) and of the G13 detector.
# Sensitive-looking values are assembled at run time so this file never trips G13 itself.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export GATES_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$GATES_ROOT"
  # shellcheck source=test/gates/lib/gates.bash
  source "$REPO/test/gates/lib/gates.bash"
  SCAN="$REPO/test/gates/lib/scan-public.sh"
}

@test "framework: a gate that discovers 0 subjects fails and says so" {
  run gate_discover GX .github -type f -name '*.yml'
  [ "$status" -eq 1 ]
}

@test "framework: discovery is relative to GATES_ROOT and finds new files without any registration" {
  mkdir -p "$GATES_ROOT/.github/workflows"
  : >"$GATES_ROOT/.github/workflows/lego-aws-new.yml"
  gate_discover GX .github/workflows -type f -name 'lego-aws-*.yml'
  [ "${GATE_SUBJECTS[0]}" = ".github/workflows/lego-aws-new.yml" ]
}

@test "framework: a violation without an exception fails and names the file" {
  GATE_VIOLATIONS=("some/file.yml|it is wrong")
  run gate_finish GX
  [ "$status" -eq 1 ]
}

@test "framework: an exception needs BOTH the marker and the entry" {
  mkdir -p "$GATES_ROOT/docs" "$GATES_ROOT/scripts"
  printf 'exceptions:\n  - gate: GX\n    file: scripts/a.sh\n    reason: test\n    expires: 2999-01-01\n' >"$GATES_ROOT/docs/exceptions.yml"
  printf '#!/bin/sh\n' >"$GATES_ROOT/scripts/a.sh"
  GATE_VIOLATIONS=("scripts/a.sh|bad")
  run gate_finish GX
  [ "$status" -eq 1 ] # entry without marker
  printf '#!/bin/sh\n# gate-exception: GX\n' >"$GATES_ROOT/scripts/a.sh"
  GATE_VIOLATIONS=("scripts/a.sh|bad")
  run gate_finish GX
  [ "$status" -eq 0 ] # both present
}

@test "framework: a stale exception (the file no longer violates) fails the gate" {
  mkdir -p "$GATES_ROOT/docs" "$GATES_ROOT/scripts"
  printf 'exceptions:\n  - gate: GX\n    file: scripts/a.sh\n    reason: test\n    expires: 2999-01-01\n' >"$GATES_ROOT/docs/exceptions.yml"
  printf '#!/bin/sh\n# gate-exception: GX\n' >"$GATES_ROOT/scripts/a.sh"
  GATE_VIOLATIONS=()
  run gate_finish GX
  [ "$status" -eq 1 ]
}

@test "framework: an expired exception fails the gate" {
  mkdir -p "$GATES_ROOT/docs" "$GATES_ROOT/scripts"
  printf 'exceptions:\n  - gate: GX\n    file: scripts/a.sh\n    reason: test\n    expires: 2000-01-01\n' >"$GATES_ROOT/docs/exceptions.yml"
  printf '#!/bin/sh\n# gate-exception: GX\n' >"$GATES_ROOT/scripts/a.sh"
  GATE_VIOLATIONS=("scripts/a.sh|bad")
  run gate_finish GX
  [ "$status" -eq 1 ]
}

@test "framework: a marker in the code without an entry fails the gate" {
  mkdir -p "$GATES_ROOT/scripts"
  printf '#!/bin/sh\n# gate-exception: GX\n' >"$GATES_ROOT/scripts/a.sh"
  GATE_VIOLATIONS=()
  run gate_finish GX
  [ "$status" -eq 1 ]
}

@test "G13 detector: 0 files to scan exits 2" {
  run "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 2 ]
}

@test "G13 detector: flags a 12-digit account id and names the file and line" {
  printf 'role: %s\n' "$(printf '%s' 1234 5678 9012)" >"$GATES_ROOT/leak.yml"
  run "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"leak.yml:1: 12-digit cloud account id"* ]]
}

@test "G13 detector: flags an arn with a literal account, an e-mail, a private IP and a foreign host" {
  acct="$(printf '%s' 1234 5678 9012)"
  printf 'arn:aws:iam::%s:role/x\n' "$acct" >"$GATES_ROOT/a.txt"
  printf 'contact: dev@%s\n' "corp.io" >"$GATES_ROOT/b.txt"
  printf 'host: 10.%s.0.5\n' "20" >"$GATES_ROOT/c.txt"
  printf 'see https://intranet.%s/x\n' "corp.io" >"$GATES_ROOT/d.txt"
  run "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.txt:1: arn with a literal account id"* ]]
  [[ "$output" == *"b.txt:1: email address"* ]]
  [[ "$output" == *"c.txt:1: private IP address"* ]]
  [[ "$output" == *"d.txt:1: URL host outside the public allowlist"* ]]
}

@test "G13 detector: a regex that starts like a host pattern is not a host, a real foreign host next to it still is" {
  printf '%s\n' '"pattern": "^https://[A-Za-z0-9.-]+/[^\\s]*$"' >"$GATES_ROOT/schema.json"
  run "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 0 ]
  printf 'see https://intranet.%s/x\n' "corp.io" >"$GATES_ROOT/d.txt"
  run "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"d.txt:1: URL host outside the public allowlist"* ]]
}

@test "G13 detector: placeholders, example domains, hex digests and allowed hosts pass" {
  printf 'role: arn:aws:iam::<ACCOUNT>:role/x\nmail: a@example.com\nsha: 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8\nsee https://github.com/example-org/x and https://example.com\n' >"$GATES_ROOT/ok.md"
  run "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 0 ]
}

@test "G13 detector: an internal name from INTERNAL_DENYLIST is flagged without printing the name" {
  printf 'we deploy acme-internal-thing today\n' >"$GATES_ROOT/n.md"
  run env INTERNAL_DENYLIST="Foo, acme-internal-thing" "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"n.md:1: internal name from INTERNAL_DENYLIST"* ]]
  [[ "$output" != *"acme-internal-thing"* ]]
}

@test "G13 detector: a required but missing denylist fails" {
  printf 'hello\n' >"$GATES_ROOT/n.md"
  run env GATE_REQUIRE_DENYLIST=1 INTERNAL_DENYLIST= "$SCAN" "$GATES_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INTERNAL_DENYLIST is not configured"* ]]
}

@test "actionlint rejects a broken workflow fixture" {
  if ! command -v actionlint >/dev/null 2>&1; then
    if [[ "${REQUIRE_TOOLS:-}" == "1" ]]; then false; else skip "actionlint not installed"; fi
  fi
  mkdir -p "$BATS_TEST_TMPDIR/wf/.github/workflows"
  printf 'on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ nope.x }}\n      - uses\n' >"$BATS_TEST_TMPDIR/wf/.github/workflows/broken.yml"
  cd "$BATS_TEST_TMPDIR/wf"
  run actionlint
  [ "$status" -ne 0 ]
}
