#!/usr/bin/env bats
# G3 — every `uses:` of a third party is pinned by a full commit SHA. References to this repository's own
# composites may stay on `@main` in the source tree (release.sh rewrites them to the release SHA; gate G11).

load 'lib/gates'

@test "G3: every third-party action under .github/ is pinned by a 40-hex SHA" {
  gate_require_tools yq jq
  gate_discover G3 .github -type f '(' -name '*.yml' -o -name '*.yaml' ')'
  local f ref
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r ref; do
      case "$ref" in
        ./*) continue ;;
        docker://*)
          [[ $ref == *@sha256:* ]] || gate_violation "$f" "docker reference '$ref' is not pinned by digest"
          continue
          ;;
      esac
      if [[ $ref =~ /nextep-platform-workflows/\.github/(actions|workflows)/ ]]; then
        [[ $ref =~ @(main|[0-9a-f]{40})$ ]] || gate_violation "$f" "internal reference '$ref' must be @main (source tree) or a 40-hex SHA (release)"
        continue
      fi
      [[ $ref =~ @[0-9a-f]{40}$ ]] || gate_violation "$f" "'$ref' is not pinned by a full commit SHA"
    done < <(gate_json "$f" | jq -r '[(.jobs // {} | .[] | (.uses, ((.steps // [])[] | .uses))), ((.runs.steps // [])[] | .uses)] | .[] | select(. != null)')
  done
  gate_finish G3
}
