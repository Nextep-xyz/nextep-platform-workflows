# shellcheck shell=bash
# Gate framework. Every gate discovers its subjects ON DISK (find/yq), never from a list of imports,
# and fails when it discovers none: a gate that finds nothing proves nothing.
#
# Usage in a *.bats file:
#   load 'lib/gates'
#   @test "..." {
#     gate_discover G3 .github -type f -name '*.yml'      # sets GATE_SUBJECTS (paths relative to GATES_ROOT)
#     for f in "${GATE_SUBJECTS[@]}"; do ... gate_violation "$f" "what is wrong"; done
#     gate_finish G3                                       # applies exceptions, prints culprits, fails if any
#   }
#
# Exceptions are declared TWICE: a `# gate-exception: <gate>` marker in the file and an entry in
# docs/exceptions.yml with reason and expiry. A stale, expired or half-declared exception fails the gate.

GATES_ROOT="${GATES_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../../.." && pwd)}"
GATE_SUBJECTS=()
GATE_VIOLATIONS=()

gate_say() { { printf '# %s\n' "$*" >&3; } 2>/dev/null || printf '%s\n' "$*" >&2; }

gate_fail() {
  gate_say "$*"
  return 1
}

gate_require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || {
      gate_fail "required tool '$t' is not installed: a gate that cannot run proves nothing"
      return 1
    }
  done
}

# gate_discover <gate> <find args...>  (run from GATES_ROOT; paths come back relative to it)
gate_discover() {
  local gate=$1 f
  shift
  GATE_SUBJECTS=()
  GATE_VIOLATIONS=()
  while IFS= read -r -d '' f; do
    GATE_SUBJECTS+=("${f#./}")
  done < <(cd "$GATES_ROOT" && find "$@" -print0 2>/dev/null | sort -z)
  if ((${#GATE_SUBJECTS[@]} == 0)); then
    gate_fail "$gate: 0 subjects discovered by 'find $*' under $GATES_ROOT (a gate that finds nothing proves nothing)"
    return 1
  fi
}

gate_violation() { GATE_VIOLATIONS+=("$1|$2"); }

gate_finish() {
  local gate=$1 v f m today exc_file expires marked
  local report=()
  today=$(date +%F)
  exc_file="$GATES_ROOT/docs/exceptions.yml"
  declare -A entry_expires=() entry_seen=()

  if [[ -f $exc_file ]]; then
    while IFS=$'\t' read -r f expires; do
      [[ -n $f ]] && entry_expires[$f]=$expires
    done < <(GATE="$gate" yq -r '.exceptions[]? | select(.gate == strenv(GATE)) | [.file, .expires] | @tsv' "$exc_file")
  fi

  for v in "${GATE_VIOLATIONS[@]}"; do
    f=${v%%|*}
    m=${v#*|}
    if [[ -n ${entry_expires[$f]:-} ]]; then
      entry_seen[$f]=1
      grep -Eq "^[[:space:]]*#[[:space:]]*gate-exception: $gate\b" "$GATES_ROOT/$f" ||
        report+=("$f: has an entry in docs/exceptions.yml but no '# gate-exception: $gate' marker in the file")
      [[ ${entry_expires[$f]} < $today ]] &&
        report+=("$f: the $gate exception expired on ${entry_expires[$f]}")
    else
      report+=("$f: $m")
    fi
  done

  for f in "${!entry_expires[@]}"; do
    [[ -n ${entry_seen[$f]:-} ]] ||
      report+=("$f: stale $gate exception in docs/exceptions.yml (the file no longer violates the gate)")
  done

  # markers in the code without an entry in docs/exceptions.yml
  while IFS= read -r marked; do
    [[ -z $marked ]] && continue
    [[ -n ${entry_expires[$marked]:-} ]] ||
      report+=("$marked: '# gate-exception: $gate' marker without an entry in docs/exceptions.yml")
  done < <(cd "$GATES_ROOT" && grep -rlE "^[[:space:]]*#[[:space:]]*gate-exception: $gate\b" .github contracts scripts 2>/dev/null | sed 's|^\./||' | sort -u)

  if ((${#report[@]} > 0)); then
    gate_say "$gate FAILED (${#report[@]} problem(s)):"
    for m in "${report[@]}"; do gate_say "  - $m"; done
    return 1
  fi
}

# The reusable workflows of this repo. Gates about them fail with 0 subjects until the first one exists.
gate_discover_lego_workflows() {
  gate_discover "$1" .github/workflows -maxdepth 1 -type f -name 'lego-aws-*.yml'
}

# JSON view of a YAML file under GATES_ROOT.
gate_json() { yq -o=json '.' "$GATES_ROOT/$1"; }

# Normalised JSON of the workflow_call inputs: {name: {type, required, default}}
gate_workflow_inputs_json() {
  yq -o=json '.on.workflow_call.inputs // {}' "$GATES_ROOT/$1" |
    jq -S 'map_values({type: .type, required: (.required // false), default: (.default // null)})'
}
