#!/usr/bin/env bats
# G13 — this repository is public: no internal names, accounts, domains, e-mails or private IPs.

load 'lib/gates'

@test "G13: the repository contains no internal names, accounts, e-mails, private IPs or foreign hosts" {
  gate_require_tools git
  local require=0
  if [[ "${CI:-}" == "true" && "${GATE_FORK_PR:-}" != "true" ]]; then require=1; fi
  run env GATE_REQUIRE_DENYLIST="$require" "$GATES_ROOT/test/gates/lib/scan-public.sh" "$GATES_ROOT"
  if [[ $status -ne 0 ]]; then
    gate_say "G13 FAILED:"
    gate_say "$output"
  fi
  [ "$status" -eq 0 ]
}
