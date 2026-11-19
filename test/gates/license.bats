#!/usr/bin/env bats
# L1 — this repository is Apache-2.0: the root LICENSE is the canonical text (sha256 pinned, so nobody edits the legal text by accident)
# and NOTICE carries the copyright line. The subjects are discovered on disk and the gate fails when it finds none.

load 'lib/gates'

# sha256 of the canonical Apache-2.0 text published by apache.org (11358 bytes, LF).
CANONICAL_LICENSE_SHA256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

@test "L1: LICENSE is the canonical Apache-2.0 text and NOTICE names the copyright holder" {
  gate_require_tools sha256sum
  gate_discover L1 . -maxdepth 1 -type f \( -name LICENSE -o -name NOTICE \)
  local want f sha
  for want in LICENSE NOTICE; do
    printf '%s\n' "${GATE_SUBJECTS[@]}" | grep -qx "$want" || gate_violation "$want" "missing from the repository root"
  done
  for f in "${GATE_SUBJECTS[@]}"; do
    case $f in
      LICENSE)
        sha=$(sha256sum "$GATES_ROOT/$f" | cut -d' ' -f1)
        [[ $sha == "$CANONICAL_LICENSE_SHA256" ]] ||
          gate_violation "$f" "is not the canonical Apache-2.0 text (sha256 differs); it is replaced by the original from apache.org, never edited"
        ;;
      NOTICE)
        grep -qE 'Copyright [0-9]{4} [^[:space:]]' "$GATES_ROOT/$f" ||
          gate_violation "$f" "must carry a 'Copyright <year> <holder>' line"
        ;;
    esac
  done
  gate_finish L1
}
