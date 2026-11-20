#!/usr/bin/env bash
# Evidence of the @nextep/* packages of a repository, written to the step summary of the run (GITHUB_STEP_SUMMARY). It is meant to be
# screenshotted, so it must be HONEST: nothing here is a fixed "all OK" text. Every mark comes from what is on disk and from the real outcome
# of the validation steps (steps.<id>.outcome), which the workflow hands over through VALIDATIONS.
#   packages-evidence.sh run      (what the composite calls) renders in a CHILD process and appends the result to the summary. It NEVER fails
#                                 the job: if the rendering itself breaks, the summary gets a red block saying so (never nothing, never green)
#                                 and a ::warning:: is emitted. A report must not turn a good CI red, nor hide a red one.
#   packages-evidence.sh render   prints the Markdown block to stdout and exits non-zero on an internal error (used by `run` and by the tests).
# Env: INSTALL_DIRS (default ".") PACKAGE_MANAGER (npm | pnpm, default pnpm)
#      VALIDATIONS      one `<label>=<outcome>` per line; outcome is steps.<id>.outcome (success | failure | cancelled | skipped)
#      JOB_WORKFLOW_REF github.job_workflow_ref (the exact platform tag that ran)
#      GITHUB_REPOSITORY GITHUB_SHA GITHUB_REF GITHUB_SERVER_URL GITHUB_RUN_ID GITHUB_RUN_ATTEMPT (set by the runner)
# What it reads: every package.json under each install root (found on disk; node_modules, .git and cdk.out skipped) and the lockfile of that root.
# What it runs: only `<dir>/node_modules/.bin/nextep-guardrails --list-rules` of an ALREADY installed package, with a minimal environment
# (no secret, no token, no network: it never goes through npx/pnpm exec, which could fetch). No other command of the repository is run.
# What it prints: names, versions, URLs and rule ids inside code spans (backticks and pipes neutralised). Never an environment variable.
# Peer dependencies are not listed: a range there is the point of a peer dependency, not a pinning defect.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

# A package is distributed as the tarball of a GitHub Release (lego-package-release). Anything else is not Release evidence.
GITHUB_HOST_RE='github\.com' # in a variable so the public-names scan (G13) does not read the escaped dot as the end of a host
RELEASE_URL_RE="^https://${GITHUB_HOST_RE}/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._@-]+\\.tgz\$"
EXACT_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
NAME_RE='^@nextep/[a-z0-9][a-z0-9._-]*$'
RULE_ID_RE='^[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)+$'
# The one package whose binary output is evidence (package -> binary). It is the contract of the evidence, not a list of what to look at:
# the dependencies themselves are discovered on disk.
GUARDRAILS_PACKAGE='@nextep/cdk-guardrails'
GUARDRAILS_BIN='nextep-guardrails'
SEP=$'\x1f' # jq output separator: not whitespace, so an empty field survives `read`
NOT_GREEN_MARKER='<!-- evidence:not-green -->'
TICK=$'\x60' # a backtick, kept out of single-quoted strings

# --- Markdown helpers: everything that comes from the repository goes through code() --------------------------------------------------
code() {
  local s=${1//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//"$TICK"/\'}
  s=${s//|/¦}
  printf '%s%s%s' "$TICK" "$s" "$TICK"
}
join_by() { # join_by <separator> <item>...
  local sep=$1 out="" first=1 i
  shift
  for i in "$@"; do
    if ((first)); then out=$i; first=0; else out+="$sep$i"; fi
  done
  printf '%s' "$out"
}
short_integrity() { # sha512-AbCdEfGhIjKl…xyz=  (the full value is in the lockfile of the commit shown in the header)
  local v=$1
  if ((${#v} > 32)); then printf '%s…%s' "${v:0:18}" "${v: -6}"; else printf '%s' "$v"; fi
}

# lookup_pnpm <lock.json> <importer> <name>  ->  <version-key> SEP <version> SEP <integrity> SEP <tarball>   (nothing when not found)
lookup_pnpm() {
  jq -r --arg imp "$2" --arg n "$3" '
    (if has("importers") then .importers[$imp] else . end) as $i
    | ([$i.dependencies, $i.devDependencies, $i.optionalDependencies] | map(select(. != null) | .[$n]) | map(select(. != null)) | first) as $d
    | if $d == null then empty else
        ($d | if type == "object" then .version else . end | tostring | sub("\\(.*$"; "")) as $vk
        | ((.packages // {}) | (.[$n + "@" + $vk] // .["/" + $n + "@" + $vk] // {})) as $p
        | [$vk, ($p.version // ""), ($p.resolution.integrity // ""), ($p.resolution.tarball // "")] | join("\u001f")
      end' "$1"
}
# lookup_npm <lock.json> <nested-key> <root-key>  ->  <version> SEP <resolved> SEP <integrity> SEP <link|"">   (nothing when not found)
lookup_npm() {
  jq -r --arg a "$2" --arg b "$3" '
    ((.packages // {}) | (.[$a] // .[$b])) as $p
    | if $p == null then empty
      else [($p.version // ""), ($p.resolved // ""), ($p.integrity // ""), (if $p.link == true then "link" else "" end)] | join("\u001f") end' "$1"
}

# --- the Markdown block ----------------------------------------------------------------------------------------------------------------
render() {
  local pm="${PACKAGE_MANAGER:-pnpm}" lock lockfiles lf
  case "$pm" in pnpm) lock=pnpm-lock.yaml ;; npm) lock=package-lock.json ;; *) die "packages-evidence: package-manager must be npm or pnpm (got '$pm')" ;; esac
  command -v jq >/dev/null || die "packages-evidence: jq is required"
  if [[ $pm == pnpm ]]; then command -v yq >/dev/null || die "packages-evidence: yq is required to read pnpm-lock.yaml"; fi
  work="$(mktemp -d)" # global on purpose: the EXIT trap below reads it after this function has returned
  trap 'rm -rf "$work"' EXIT

  # Package roots: the same validated list the install used (one source of truth for what a root is).
  local roots=()
  lockfiles="$(INSTALL_DIRS="${INSTALL_DIRS:-.}" PACKAGE_MANAGER="$pm" "$here/install-dirs.sh" lockfiles)"
  while IFS= read -r lf; do [[ -n $lf ]] && roots+=("$(dirname "$lf")"); done <<<"$lockfiles"
  ((${#roots[@]} > 0)) || die "packages-evidence: no package root"

  local rows=() guard_rows=() manifests=0 declared=0 bad=0
  local root m mdir rel lockjson section name spec problems version origin integrity exact origin_cell integrity_cell status
  local v res_version res_integrity res_tarball link found rkey bin out rc ids line id shown version_cell evidenced=0
  for root in "${roots[@]}"; do
    [[ -d $root ]] || continue
    lockjson=""
    if [[ -f $root/$lock ]]; then
      lockjson="$work/lock-${root//\//_}.json"
      if [[ $pm == pnpm ]]; then
        yq -o=json '.' "$root/$lock" >"$lockjson" 2>/dev/null || lockjson="UNREADABLE"
      else
        jq -c '.' "$root/$lock" >"$lockjson" 2>/dev/null || lockjson="UNREADABLE"
      fi
    fi
    while IFS= read -r -d '' m; do
      m="${m#./}"
      manifests=$((manifests + 1))
      mdir="$(dirname "$m")"
      if [[ $mdir == "$root" ]]; then rel="."; else rel="${mdir#"$root"/}"; fi
      if ! jq -e 'type == "object"' "$m" >/dev/null 2>&1; then
        # Not JSON: say so when it mentions a package of ours instead of silently skipping it.
        grep -q '@nextep/' "$m" 2>/dev/null || continue
        declared=$((declared + 1))
        bad=$((bad + 1))
        rows+=("| — | $(code "$m") | — | — | — | — | ❌ the manifest is not valid JSON |")
        continue
      fi
      while IFS="$SEP" read -r section name spec; do
        [[ -n $name ]] || continue
        declared=$((declared + 1))
        problems=() version="" origin="" integrity="" exact="" v="" res_version="" res_integrity="" res_tarball="" link="" found=0
        [[ $name =~ $NAME_RE ]] || problems+=("invalid package name")

        # 1. what package.json declares
        if [[ $spec == workspace:* ]]; then
          exact="workspace"
        elif [[ $spec =~ $EXACT_RE ]]; then
          exact="yes"
        elif [[ $spec =~ $RELEASE_URL_RE ]]; then
          exact="yes (Release URL)"
        else
          exact="no: $(code "$spec")"
          problems+=("not an exact version")
        fi

        # 2. what the lockfile resolved
        if [[ -z $lockjson ]]; then
          problems+=("no lockfile ($root/$lock)")
        elif [[ $lockjson == UNREADABLE ]]; then
          problems+=("the lockfile is unreadable")
        elif [[ $exact != workspace ]]; then
          if [[ $pm == pnpm ]]; then
            IFS="$SEP" read -r v res_version res_integrity res_tarball < <(lookup_pnpm "$lockjson" "$rel" "$name") || true
            if [[ -n $v ]]; then
              found=1
              version="${res_version:-$v}"
              origin="$res_tarball"
              [[ -n $origin || ! $v =~ ^https:// ]] || origin="$v"
              integrity="$res_integrity"
            fi
          else
            rkey="node_modules/$name"
            [[ $rel == "." ]] || rkey="$rel/node_modules/$name"
            IFS="$SEP" read -r version origin integrity link < <(lookup_npm "$lockjson" "$rkey" "node_modules/$name") || true
            if [[ -n $version$origin$integrity$link ]]; then
              found=1
              if [[ $link == link ]]; then
                exact="workspace"
                origin="workspace"
              fi
            fi
          fi
          if ((!found)); then
            problems+=("not found in the lockfile")
          elif [[ $exact != workspace ]]; then
            [[ $origin =~ $RELEASE_URL_RE ]] || problems+=("origin is not a GitHub Release URL")
            [[ -n $integrity ]] || problems+=("no integrity in the lockfile")
          fi
        fi

        if [[ -n $origin && $origin != workspace ]]; then origin_cell="$(code "$origin")"; else origin_cell="${origin:-—}"; fi
        if [[ -n $integrity ]]; then integrity_cell="$(code "$(short_integrity "$integrity")")"; else integrity_cell="—"; fi
        if ((${#problems[@]} > 0)); then
          bad=$((bad + 1))
          status="❌ $(join_by '; ' "${problems[@]}")"
        elif [[ $exact == workspace ]]; then
          status="➖ in-repo package, not a Release"
        else
          status="✅"
          evidenced=$((evidenced + 1))
        fi
        if [[ -n $version ]]; then version_cell="$(code "$version")"; else version_cell="—"; fi
        rows+=("| $(code "$name") | $(code "$m") ($section) | $version_cell | $origin_cell | $integrity_cell | $exact | $status |")

        # 3. the binary of the package that has one: the INSTALLED copy, offline, nothing but the rule ids reach the summary
        if [[ $name == "$GUARDRAILS_PACKAGE" && $exact != workspace ]]; then
          bin="$mdir/node_modules/.bin/$GUARDRAILS_BIN"
          if [[ ! -x $bin ]]; then
            bad=$((bad + 1))
            guard_rows+=("| $(code "$name") | $(code "$mdir") | — | ❌ not installed: $(code "$bin") does not exist |")
          else
            out="" rc=0 ids=()
            out="$(cd "$mdir" && env -i PATH="$PATH" HOME="${HOME:-/}" LC_ALL=C timeout 60 "./node_modules/.bin/$GUARDRAILS_BIN" --list-rules 2>/dev/null </dev/null)" || rc=$?
            while IFS= read -r line; do
              id="${line%%[[:space:]]*}"
              if [[ $id =~ $RULE_ID_RE ]]; then ids+=("$id"); fi
            done <<<"$out"
            if ((rc != 0)); then
              bad=$((bad + 1))
              guard_rows+=("| $(code "$name") | $(code "$mdir") | — | ❌ $(code "$GUARDRAILS_BIN --list-rules") exited with code $rc |")
            elif ((${#ids[@]} == 0)); then
              bad=$((bad + 1))
              guard_rows+=("| $(code "$name") | $(code "$mdir") | 0 | ❌ the command listed no rules |")
            else
              shown="$(join_by ', ' "${ids[@]:0:100}")"
              if ((${#ids[@]} > 100)); then shown+=", … (+$((${#ids[@]} - 100)) more)"; fi
              guard_rows+=("| $(code "$name") | $(code "$mdir") | ${#ids[@]} | $shown |")
            fi
          fi
        fi
      done < <(jq -r '[("dependencies", "devDependencies", "optionalDependencies") as $s
          | (.[$s] | if type == "object" then . else {} end) | to_entries[]
          | select(.key | startswith("@nextep/")) | [$s, .key, (.value | tostring)] | join("\u001f")] | .[]' "$m")
    done < <(find "$root" \( -name node_modules -o -name .git -o -name cdk.out \) -prune -o -type f -name package.json -print0 | sort -z)
  done

  # --- validations: the REAL outcome of the steps, never a fixed text -----------------------------------------------------------------
  local val_labels=() val_marks=() val_bad=0 val_skipped=0 val_ok=0 label outcome mark
  if [[ -n ${VALIDATIONS:-} ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -n ${line//[[:space:]]/} ]] || continue
      label="${line%%=*}"
      outcome=""
      [[ $line != *=* ]] || outcome="${line#*=}"
      case "$outcome" in
        success)
          val_ok=$((val_ok + 1))
          mark="✅ passed"
          ;;
        skipped)
          val_skipped=$((val_skipped + 1))
          mark="⏭️ did not run (skipped)"
          ;;
        failure)
          val_bad=$((val_bad + 1))
          mark="❌ FAILED"
          ;;
        cancelled)
          val_bad=$((val_bad + 1))
          mark="❌ cancelled"
          ;;
        *)
          val_bad=$((val_bad + 1))
          mark="❌ unknown outcome $(code "$outcome")"
          ;;
      esac
      val_labels+=("$label")
      val_marks+=("$mark")
    done <<<"$VALIDATIONS"
  fi
  local nval=$((val_ok + val_skipped + val_bad))
  # A block wired to no validation says nothing about them: that is a defect of the workflow, shown as one (never a quiet pass).
  if ((nval == 0)); then val_bad=1; fi

  # --- verdict: green only when at least one package is evidenced, every row is green and every validation passed. Nothing to evidence
  # (no package, or only in-repo ones) is n/a, never a tick -------------------------------------------------------------------------------
  local verdict
  if ((bad > 0 || val_bad > 0)); then
    verdict="❌ FAILED"
  elif ((evidenced == 0)); then
    verdict="n/a"
  elif ((val_skipped > 0)); then
    verdict="⏭️ INCOMPLETE (the validations did not run)"
  else
    verdict="✅ VERIFIED"
  fi

  # --- output --------------------------------------------------------------------------------------------------------------------------
  local sha="${GITHUB_SHA:-unknown}" attempt="${GITHUB_RUN_ATTEMPT:-1}" run_url run_cell i
  run_url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  if [[ $run_url =~ ^https://[A-Za-z0-9./_-]+$ && $attempt =~ ^[0-9]+$ ]]; then
    run_cell="[${GITHUB_RUN_ID} (attempt ${attempt})](${run_url}/attempts/${attempt})"
  else
    run_cell="$(code "${GITHUB_RUN_ID:-unknown}")"
  fi
  printf '## @nextep/* packages evidence: %s\n\n' "$verdict"
  printf '| | |\n|---|---|\n'
  printf '| Repository | %s |\n' "$(code "${GITHUB_REPOSITORY:-unknown}")"
  printf '| Commit | %s |\n' "$(code "${sha:0:7}")"
  printf '| Ref | %s |\n' "$(code "${GITHUB_REF:-unknown}")"
  printf '| Generated (UTC) | %s |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '| Run | %s |\n' "$run_cell"
  printf '| Platform | %s |\n' "$(code "${JOB_WORKFLOW_REF:-unknown}")"
  printf '| Roots scanned | %s (%s package.json) |\n\n' "$(code "$(join_by ',' "${roots[@]}")")" "$manifests"

  if ((declared == 0)); then
    printf '### Packages\n\n**n/a**: none of the %s package.json file(s) declares a %s dependency, so there is no package evidence to show.\n\n' "$manifests" "$(code '@nextep/*')"
  else
    printf '### Packages (%s found, %s with a problem)\n\n' "$declared" "$bad"
    printf '| Package | Declared in | Version | Origin | Integrity (lockfile) | Exact | Status |\n|---|---|---|---|---|---|---|\n'
    printf '%s\n' "${rows[@]}"
    printf '\nThe integrity is abbreviated; the full value is in the lockfile of the commit above.\n\n'
  fi
  if ((${#guard_rows[@]} > 0)); then
    printf '### Guardrails rules (output of the installed package, offline)\n\n'
    printf '| Package | Root | Rules | Rule ids |\n|---|---|---|---|\n'
    printf '%s\n\n' "${guard_rows[@]}"
  fi

  printf '### Validations\n\n'
  if ((nval == 0)); then
    printf '❌ No validation outcome was reported to this block, so nothing can be said about them.\n'
  else
    printf '| Check | Result |\n|---|---|\n'
    for i in "${!val_labels[@]}"; do
      mark="${val_marks[$i]}"
      # With no package to evidence, a pass is not a mark of evidence: it is printed as a plain fact (never a tick).
      if ((evidenced == 0)) && [[ $mark == "✅ passed" ]]; then mark="➖ passed (no packages to evidence)"; fi
      printf '| %s | %s |\n' "$(code "${val_labels[$i]}")" "$mark"
    done
  fi
  if ((bad > 0 || val_bad > 0)); then printf '\n%s\n' "$NOT_GREEN_MARKER"; fi
}

# --- run: render in a child process (its own errexit), append only a COMPLETE block, never fail the job --------------------------------
run() {
  local summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}" tmp err rc=0
  tmp="$(mktemp)"
  err="$(mktemp)"
  bash "${BASH_SOURCE[0]}" render >"$tmp" 2>"$err" || rc=$?
  if ((rc != 0)); then
    printf '::warning::packages evidence: could not be generated (exit %s): %s\n' "$rc" "$(tail -n 1 "$err" | tr -d '\r' | sed 's/^::[a-z]*:://' | cut -c1-200)" >&2
    printf '## @nextep/* packages evidence: ❌ COULD NOT BE GENERATED\n\nThe evidence step failed (exit code %s) before it could read the packages. **Treat this run as having NO package evidence.** The validation steps of the run are not affected by this.\n' "$rc" >>"$summary"
  else
    if grep -qF "$NOT_GREEN_MARKER" "$tmp"; then
      printf '::warning::packages evidence: at least one package or validation is not green; see the summary of the run\n' >&2
    fi
    cat "$tmp" >>"$summary"
  fi
  rm -f "$tmp" "$err"
}

cmd="${1:-run}"
case "$cmd" in
  render) render ;;
  run) run ;;
  *) die "packages-evidence: unknown subcommand '$cmd'" ;;
esac
