# shellcheck shell=bash
# Shape of the optional `root-kinds` input (docs/runbook.md section 11.6), shared by validate-inputs.sh (which fails the job on a malformed value)
# and packages-evidence.sh (which refuses to render with one): one definition, so the two can never disagree.
# The value is a JSON object {"<root>": "<kind>"}: the kind of each root of the repository.
# The vocabulary is closed. It is declared here, in contracts/package-profiles.yml and in the description of the input; the gate RK-PROFILES
# crosses the three, so adding a kind in one place and forgetting another breaks the build.

ROOT_KINDS_VOCAB=(iac backend frontend platform)

# root_kinds_shown <string>: the string made safe to print in an error (anything outside a path alphabet becomes '?', 60 characters at most),
# so a crafted key cannot inject a workflow command or reshape a log line.
root_kinds_shown() {
  local s=${1//[^A-Za-z0-9._\/-]/?}
  printf '%s' "${s:0:60}"
}

# root_kinds_problems <value>: prints one problem per line (nothing when the value is fine or empty). It never exits: the caller decides what a
# problem means (validate-inputs.sh reports them all, packages-evidence.sh dies on the first).
# The rule for what a root is lives in install-dirs.sh (relative path, no '..', no absolute path, no backslash, no glob): it is called once per
# key, so there is a single definition. `.` is always valid (a Python repository does not list it in install-dirs).
root_kinds_problems() {
  local json=$1 entry key vtype kind shown here valid
  here="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
  valid="$(printf '%s, ' "${ROOT_KINDS_VOCAB[@]}")"
  valid="${valid%, }"
  [[ -n $json ]] || return 0
  if ! jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1; then
    printf '%s\n' "input 'root-kinds' must be a JSON object {\"<root>\": \"<kind>\"} with kinds from: $valid (it is not valid JSON, or not an object)"
    return 0
  fi
  if jq -e 'length == 0' <<<"$json" >/dev/null; then
    printf '%s\n' "input 'root-kinds' must declare at least one root (got an empty object; leave the input empty to not use it)"
    return 0
  fi
  while IFS= read -r entry; do
    key="$(jq -r '.key' <<<"$entry")"
    vtype="$(jq -r '.value | type' <<<"$entry")"
    kind="$(jq -r '.value | tostring' <<<"$entry")"
    shown="$(root_kinds_shown "$key")"
    # install-dirs.sh reads a comma separated list, one line, and treats an empty value as '.': an empty key, a comma or a line break would
    # turn one key into the repository root or into several valid ones
    if [[ -z $key || $key == *[$',\n\r']* ]] || ! INSTALL_DIRS="$key" PACKAGE_MANAGER=pnpm "$here/install-dirs.sh" lockfiles >/dev/null 2>&1; then
      printf '%s\n' "input 'root-kinds' has an invalid root '$shown' (a relative path, '.' for the repository root: no '..', no absolute path, no backslash, no glob, no comma, no trailing '/')"
      continue
    fi
    if [[ $vtype != string ]]; then
      printf '%s\n' "input 'root-kinds': the kind of root '$shown' must be a string from: $valid (got a JSON $vtype)"
      continue
    fi
    # the kind is data, never a pattern: it is matched as a whole word of the vocabulary (a kind with a space inside never matches)
    if [[ " ${ROOT_KINDS_VOCAB[*]} " != *" $kind "* || $kind == *" "* ]]; then
      printf '%s\n' "input 'root-kinds': root '$shown' has the kind '$(root_kinds_shown "$kind")', which is not valid (valid kinds: $valid)"
    fi
  done < <(jq -c 'to_entries[]' <<<"$json")
}
