#!/usr/bin/env bash
# The packages policy of a run (docs/runbook.md section 12): it turns the verdict of the evidence (packages-evidence.sh findings) and the result of
# the guardrails step into a decision that depends on the ENVIRONMENT, and nothing else.
#   dev, stg  -> mode enforce: a finding PF-1..PF-8 fails the step (and so the job: no migration, no deploy). PF-9 only warns.
#   prod      -> mode warn:    every finding is a ::warning:: and a section of the summary, and the step exits 0: a hotfix is never held back by it.
#   anything else -> enforce (lib/enforcement.sh is the single place that decides; this script never compares an environment name).
# Env: ENVIRONMENT        the environment of the run (the workflow input `environment`)
#      ROOT_KINDS INSTALL_DIRS PACKAGE_MANAGER   as for packages-evidence.sh (the same values the evidence block receives)
#      GUARDRAILS_RESULT  what the guardrails step reported: pass | fail | warn | missing | skipped. Empty is read as skipped. `skipped` (or empty)
#                         in a repository that has an IaC root is PF-7 (the guard did not run); `missing` is PF-7 (no command / no such command);
#                         `fail` and `warn` are PF-5; anything else is PF-5 (fail-closed).
#      POLICY_PHASE       full (default) | optin. `optin` is the early check (docs/runbook.md section 12.2): it evaluates ONLY PF-1, which needs
#                         nothing but the input `root-kinds` and the files on disk, so a repository that has not opted in fails (dev, stg) or warns
#                         (prod) in seconds, BEFORE the install, the lint and the tests. The mode is the same function of the environment.
#      GITHUB_STEP_SUMMARY GITHUB_OUTPUT  (set by the runner; the summary defaults to stdout)
# Findings (the table of the spec, see docs/runbook.md section 12):
#   PF-1 no root-kinds (no opt-in)         PF-2 an install root without a declared kind      PF-3 a package required by the kind is missing
#   PF-4 CDK files in a root not declared iac   PF-5 the guard is red (plugin, Jest, CLI, or the package cannot list its rules)
#   PF-6 an IaC root that is not installed      PF-7 the guardrails command is missing or did not run in a repository with an IaC root
#   PF-8 a package of the catalog below its min_version   PF-9 below its recommended_version (never blocks)
# What it never does: network, install, secrets, a command of the caller. Everything from the repository reaches the annotations and the summary
# through lib/safe-text.sh (E11). An internal error fails the step in enforce mode and only warns in warn mode.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/enforcement.sh
source "$here/lib/enforcement.sh"
# shellcheck source=lib/root-kinds.sh
source "$here/lib/root-kinds.sh"
# shellcheck source=lib/safe-text.sh
source "$here/lib/safe-text.sh"
# shellcheck source=lib/guardrails.sh
source "$here/lib/guardrails.sh"
PROFILES_FILE="$here/../contracts/package-profiles.yml"
SEP=$'\x1f'
TICK=$'\x60'

summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
mode="$(enforcement_mode "${ENVIRONMENT-}")"
env_shown="$(safe_path "${ENVIRONMENT-}")"
[[ -n $env_shown ]] || env_shown="unset"

# annot <text>: the data part of a workflow command (a value that reaches here is already safe; this is the second wall)
annot() {
  local s=${1//'%'/'%25'}
  s=${s//$'\r'/'%0D'}
  s=${s//$'\n'/'%0A'}
  printf '%s' "$s"
}
code() { printf '%s%s%s' "$TICK" "$1" "$TICK"; }
# md_cell <text>: a table cell. The text is a sentence of the platform around safe values; the characters that would break a row or open an HTML tag are neutralised.
md_cell() {
  local s=${1//|/¦}
  s=${s//</&lt;}
  printf '%s' "${s//>/&gt;}"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# the phase of the run: the full policy, or only the early opt-in check (PF-1)
phase="${POLICY_PHASE:-full}"
title="Package policy"
[[ $phase != optin ]] || title="Package opt-in"

# --- an internal error: it blocks in enforce, it only warns in warn -----------------------------------------------------------------------
internal_error() { # internal_error <reason>
  local why
  why="$(safe_detail "$1")"
  if [[ $mode == enforce ]]; then
    printf '::error title=packages policy::packages policy (environment %s): the policy could not be evaluated: %s\n' "$env_shown" "$(annot "$why")"
    printf '### %s ❌ could not be evaluated in %s\n\n%s\n' "$title" "$env_shown" "$why" >>"$summary"
    exit 1
  fi
  printf '::warning title=packages policy::packages policy (environment %s): the policy could not be evaluated, nothing is blocked in this environment: %s\n' "$env_shown" "$(annot "$why")"
  printf '### %s ⚠️ could not be evaluated in %s (not blocking)\n\n%s\n' "$title" "$env_shown" "$why" >>"$summary"
  exit 0
}
last_error_line() { # the last line of a stderr file, without the workflow command prefix
  tail -n 1 "$1" 2>/dev/null | tr -d '\r' | sed 's/^::[a-z]*[^:]*:://' | cut -c1-200
}

# --- the verdict of the evidence (the same reading as the block) --------------------------------------------------------------------------
[[ $phase == full || $phase == optin ]] || internal_error "unknown POLICY_PHASE '$(safe_name "$phase")' (expected full or optin)"
findings="" iac_roots=""
if ! findings="$("$here/packages-evidence.sh" findings 2>"$work/err")"; then
  internal_error "packages-evidence findings failed: $(last_error_line "$work/err")"
fi
if [[ $phase == full ]] && ! iac_roots="$("$here/packages-evidence.sh" iac-roots 2>"$work/err")"; then
  internal_error "packages-evidence iac-roots failed: $(last_error_line "$work/err")"
fi
jq -e 'type == "array"' <<<"$findings" >/dev/null 2>&1 || internal_error "packages-evidence findings did not print a JSON array"
[[ -f $PROFILES_FILE ]] || internal_error "the profile file contracts/package-profiles.yml does not exist"
command -v yq >/dev/null || internal_error "yq is required to read the package profiles"
yq -o=json '.' "$PROFILES_FILE" >"$work/profiles.json" 2>/dev/null || internal_error "contracts/package-profiles.yml is not valid YAML"

# --- what each kind requires, for the messages (generated from the profile, never written by hand) ---------------------------------------
kinds_text=""
for kind in "${ROOT_KINDS_VOCAB[@]}"; do
  req="$(jq -r --arg k "$kind" '(.kinds[$k].required // []) | if length == 0 then "nothing defined yet" else join(", ") end' "$work/profiles.json")"
  kinds_text+="${kinds_text:+; }$(safe_name "$kind") -> $(safe_detail "$req")"
done
iac_requires="$(jq -r '(.kinds.iac.required // []) | join(", ")' "$work/profiles.json")"
iac_requires="$(safe_detail "$iac_requires")"

# --- the result of the guardrails step: PF-5 and PF-7 (the evidence cannot know them) -------------------------------------------------
guard_result="${GUARDRAILS_RESULT-}"
extra='[]'
add_extra() { # add_extra <id> <detail>
  extra="$(jq -c --arg id "$1" --arg pkg "$GUARDRAILS_PACKAGE" --arg detail "$(safe_detail "$2")" '. + [{id: $id, root: "", kind: "iac", package: $pkg, detail: $detail}]' <<<"$extra")"
}
has_iac=0
[[ -z $iac_roots ]] || has_iac=1
# the early opt-in check knows nothing of the guard (it runs before the install): only the full phase reads its result
[[ $phase == full ]] || guard_result="pass"
case "$guard_result" in
  pass) ;;
  fail | warn) add_extra PF-5 "the guardrails command of the caller failed (result $guard_result)" ;;
  missing) add_extra PF-7 "the guardrails command is not configured or does not exist" ;;
  skipped | "")
    if ((has_iac)); then add_extra PF-7 "the guardrails step did not run in a repository that has an IaC root"; fi
    ;;
  *) add_extra PF-5 "the guardrails step reported an unknown result '$(safe_version "$guard_result")'" ;;
esac
all="$(jq -c --argjson extra "$extra" '. + $extra | sort_by(.id, .root, (.package // ""), (.version // ""))' <<<"$findings")"
# optin: the early check carries PF-1 and nothing else (the rest needs the install and the results, and stays in the full phase)
if [[ $phase == optin ]]; then all="$(jq -c '[.[] | select(.id == "PF-1")]' <<<"$all")"; fi

# --- one message per finding --------------------------------------------------------------------------------------------------------------
message() { # message <id> <root> <kind> <package> <version> <min> <recommended> <detail>
  local id=$1 root=$2 kind=$3 pkg=$4 ver=$5 min=$6 rec=$7 detail=$8 where=""
  [[ -z $root ]] || where="root '$root' "
  case "$id" in
    PF-1)
      local detected=""
      [[ $detail != root* ]] || detected=" Detected: $detail."
      printf "this repository has not opted in. Declare the kind of every root with the input 'root-kinds', for example {\"<root>\":\"<kind>\"}. What each kind requires: %s.%s" "$kinds_text" "$detected"
      ;;
    PF-2) printf "%sis an install root with no declared kind: declare it with the input 'root-kinds'. What each kind requires: %s." "$where" "$kinds_text" ;;
    PF-3) printf "%s(kind %s) does not declare %s, which that kind requires: %s." "$where" "$kind" "$pkg" "$detail" ;;
    PF-4) printf "%shas CDK files but is not declared iac, and kind iac requires %s: %s." "$where" "$iac_requires" "$detail" ;;
    PF-5) printf "the guardrails check is red (kind %s requires %s): %s." "${kind:-iac}" "${pkg:-$GUARDRAILS_PACKAGE}" "$detail" ;;
    PF-6) printf "%s(kind %s) requires %s and is not installed: %s." "$where" "$kind" "$pkg" "$detail" ;;
    PF-7) printf "kind iac requires %s and its guard did not run: %s. Give the input 'guardrails-command' a command that runs %s." "$iac_requires" "$detail" "$GUARDRAILS_BIN" ;;
    PF-8) printf "%s %s is below the minimum %s (recommended %s)%s: upgrade it. %s." "$pkg" "$ver" "$min" "$rec" "${kind:+, used by kind $kind}" "$detail" ;;
    PF-9) printf "%s %s is below the recommended %s (the minimum is %s)%s: upgrade it when you can. %s." "$pkg" "$ver" "$rec" "$min" "${kind:+, used by kind $kind}" "$detail" ;;
    *) printf 'unknown finding %s: %s' "$id" "$detail" ;;
  esac
}

blocking=0 total=0 rows=()
while IFS="$SEP" read -r id root kind pkg ver min rec detail; do
  [[ -n $id ]] || continue
  # the values come from a JSON the evidence built, and are reduced again here: this script never trusts what it will print
  id="$(safe_name "$id")"
  root="$(safe_path "$root")" kind="$(safe_name "$kind")" pkg="$(safe_name "$pkg")" ver="$(safe_version "$ver")"
  min="$(safe_version "$min")" rec="$(safe_version "$rec")" detail="$(safe_detail "$detail")"
  total=$((total + 1))
  msg="$(message "$id" "$root" "$kind" "$pkg" "$ver" "$min" "$rec" "$detail")"
  text="packages policy (environment $env_shown): $msg"
  # PF-9 never blocks, in any environment; in warn mode nothing blocks
  if [[ $mode == enforce && $id != PF-9 ]]; then
    blocking=$((blocking + 1))
    printf '::error title=%s::%s\n' "$id" "$(annot "$text")"
    rows+=("| $id | ❌ blocks | ${root:+$(code "$root")} ${pkg:+$(code "$pkg")} | $(md_cell "$msg") |")
  else
    printf '::warning title=%s::%s\n' "$id" "$(annot "$text")"
    rows+=("| $id | ⚠️ warning | ${root:+$(code "$root")} ${pkg:+$(code "$pkg")} | $(md_cell "$msg") |")
  fi
done < <(jq -r '.[] | [.id, .root, .kind, (.package // ""), (.version // ""), (.min // ""), (.recommended // ""), .detail] | join("\u001f")' <<<"$all")

# --- the summary: a section every time, honest about what it did and about the environment ---------------------------------------------------
{
  if ((total == 0)); then
    if [[ $phase == optin ]]; then
      printf '### %s ✅ declared in %s (mode %s)\n\nThe repository declares %s. The rest of the policy runs after the install and the quality gate.\n' "$title" "$env_shown" "$mode" "$(code root-kinds)"
    else
      printf '### %s ✅ passed in %s (mode %s)\n\nNo finding. The policy evaluated every root and every %s package against the catalog.\n' "$title" "$env_shown" "$mode" "$(code '@nextep/*')"
    fi
  else
    if ((blocking > 0)); then
      printf '### %s ❌ blocking in %s (mode %s)\n\n' "$title" "$env_shown" "$mode"
    elif [[ $mode == warn ]]; then
      printf '### %s ⚠️ not blocking in %s (mode %s)\n\n' "$title" "$env_shown" "$mode"
    else
      printf '### %s ⚠️ warnings in %s (mode %s, nothing blocks)\n\n' "$title" "$env_shown" "$mode"
    fi
    printf '| Finding | Result | Where | What |\n|---|---|---|---|\n'
    printf '%s\n' "${rows[@]}"
  fi
} >>"$summary"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'mode=%s\nfindings=%s\nblocking=%s\n' "$mode" "$total" "$blocking" >>"$GITHUB_OUTPUT"
fi
((blocking == 0)) || exit 1
