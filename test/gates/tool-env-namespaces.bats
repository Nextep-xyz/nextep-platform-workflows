#!/usr/bin/env bats
# G27 — environment variable names that a tool reads do not get reused with another meaning.
# Origin: `DOCKER_CONTEXT=.` (the build path) made the docker CLI select a docker *context* named "." and the deploy died with
# `ERROR: no builder "." found`. The fake docker accepted it, so every gate was green.
#   (a) the container-tool namespaces (DOCKER_, BUILDX_, BUILDKIT_, COMPOSE_) are forbidden in .github/ and scripts/, no allowlist:
#       our own variables get another prefix (BUILD_CONTEXT, BUILD_TARGET).
#   (b) the other tool namespaces (AWS_, PG*, NODE_, NPM_, GH_, GIT_, PNPM_, PIP_, TF_, UV_) only appear with a name that is declared in
#       test/gates/lib/tool-env-allowed.txt with the reason it is used. A new name must be declared on purpose, by someone who read this.
#   (c) a declared name that no file uses any more fails the gate (stale allowlist).
# The allowlist path can be overridden with TOOL_ENV_ALLOWLIST (the red tests do).

load 'lib/gates'

CONTAINER_NS='(DOCKER|BUILDX|BUILDKIT|COMPOSE)_[A-Z0-9_]+'
OTHER_NS='((AWS|GH|GIT|NPM|PNPM|PIP|NODE|TF|UV)_[A-Z0-9_]+|PG[A-Z]{3,}[A-Z0-9_]*)'

allowlist_file() { printf '%s' "${TOOL_ENV_ALLOWLIST:-$BATS_TEST_DIRNAME/lib/tool-env-allowed.txt}"; }

@test "G27 (a): no container-tool variable (DOCKER_*, BUILDX_*, BUILDKIT_*, COMPOSE_*) is named in .github/ or scripts/" {
  gate_discover G27 .github scripts -type f
  local f name
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r name; do
      gate_violation "$f" "names $name: the docker/buildx/compose CLI reads that namespace and changes behaviour (DOCKER_CONTEXT=. broke the build once); use another prefix (BUILD_*)"
    done < <(grep -ohwE "$CONTAINER_NS" "$GATES_ROOT/$f" | sort -u)
  done
  gate_finish G27
}

@test "G27 (b)+(c): every other tool-namespace variable is declared in tool-env-allowed.txt, and no declared name is stale" {
  local list
  list="$(allowlist_file)"
  [ -f "$list" ] || { gate_say "G27: allowlist $list not found"; return 1; }
  declare -A allowed=() used=()
  local line name reason
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
    name="${line%%[[:space:]]*}"
    reason="${line#*#}"
    [[ $line == *'#'* && -n ${reason//[[:space:]]/} ]] || gate_say "G27: allowlist entry '$name' has no '# reason'"
    [[ $line == *'#'* && -n ${reason//[[:space:]]/} ]] || return 1
    allowed[$name]=1
  done <"$list"

  gate_discover G27 .github scripts -type f
  local f
  for f in "${GATE_SUBJECTS[@]}"; do
    while IFS= read -r name; do
      used[$name]=1
      [[ -n ${allowed[$name]:-} ]] ||
        gate_violation "$f" "names $name, a variable in a tool namespace that is not declared in test/gates/lib/tool-env-allowed.txt (is it the tool's own variable? declare it with the reason; otherwise rename it)"
    done < <(grep -ohwE "$OTHER_NS" "$GATES_ROOT/$f" | sort -u)
  done
  for name in "${!allowed[@]}"; do
    [[ -n ${used[$name]:-} ]] || gate_violation "test/gates/lib/tool-env-allowed.txt" "stale entry $name: no file under .github/ or scripts/ uses it any more"
  done
  gate_finish G27
}
