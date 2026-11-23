#!/usr/bin/env bash
# Evidence of the @nextep/* packages of a repository, written to the step summary of the run (GITHUB_STEP_SUMMARY). It is meant to be
# screenshotted, so it must be HONEST: nothing here is a fixed "all OK" text. Every mark comes from what is on disk and from the real outcome
# of the validation steps (steps.<id>.outcome), which the workflow hands over through VALIDATIONS.
#   packages-evidence.sh run      (what the composite calls) renders in a CHILD process and appends the result to the summary. It NEVER fails
#                                 the job: if the rendering itself breaks, the summary gets a red block saying so (never nothing, never green)
#                                 and a ::warning:: is emitted. A report must not turn a good CI red, nor hide a red one.
#   packages-evidence.sh render   prints the Markdown block to stdout and exits non-zero on an internal error (used by `run` and by the tests).
# Env: INSTALL_DIRS (default ".") PACKAGE_MANAGER (npm | pnpm, default pnpm)
#      ROOT_KINDS       optional JSON object {"<root>": "<kind>"} (iac | backend | frontend | platform). Empty = the evidence of what the repository
#                       declares, exactly as before. Set = what each kind REQUIRES (contracts/package-profiles.yml) against what the repository
#                       has: each package.json belongs to the most specific declared root, a missing required package is a red row, and a root
#                       with CDK files that is not declared iac is red too. A required package that is missing marks the block red; it never
#                       fails the job.
#      VALIDATIONS      one `<label>=<outcome>` per line; outcome is steps.<id>.outcome (success | failure | cancelled | skipped)
#      ACTION_REPOSITORY ACTION_REF  github.action_repository and github.action_ref of the composite that runs this script: the platform code
#                       that ran (the ref is the commit a release pins). Both present -> `<repository>@<ref>`; either missing -> `not available`.
#                       github.job_workflow_ref is NOT a source: it is a claim of the OIDC token, not a property of the github context (empty in
#                       a real run), and gate PE-PLATFORM keeps it out.
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
# shellcheck source=lib/root-kinds.sh
source "$here/lib/root-kinds.sh"
PROFILES_FILE="$here/../contracts/package-profiles.yml"

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
# --- roots: a directory belongs to the most specific root that contains it ------------------------------------------------------------
in_root() { # in_root <dir> <root>: the directory is the root or lives under it ('.' contains everything)
  [[ $2 == . || $1 == "$2" || $1 == "$2"/* ]]
}
root_len() { if [[ $1 == . ]]; then printf 0; else printf '%s' "${#1}"; fi; } # '.' is the least specific root, whatever its length
longest_root() { # longest_root <dir> <root>...: the most specific of the roots that contain the directory (nothing when none does)
  local d=$1 best="" r
  shift
  for r in "$@"; do
    in_root "$d" "$r" || continue
    if [[ -z $best ]] || (($(root_len "$r") > $(root_len "$best"))); then best=$r; fi
  done
  printf '%s' "$best"
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

  # root-kinds (optional): the declared roots and the policy of each kind. Empty = the evidence of v1.7.0, untouched.
  local kinds_mode=0 scan_roots=("${roots[@]}") kind_roots=() kroot lock_root r1 pair problems_rk
  declare -A kind_of=() required_of=() req_state=() lock_cache=() seen_manifest=() cdk_dirs=()
  local ignored=0 profile_json="$work/profiles.json" kind_name
  if [[ -n ${ROOT_KINDS:-} ]]; then
    kinds_mode=1
    problems_rk="$(root_kinds_problems "$ROOT_KINDS")"
    [[ -z $problems_rk ]] || die "packages-evidence: ${problems_rk%%$'\n'*}"
    [[ -f $PROFILES_FILE ]] || die "packages-evidence: the profile file contracts/package-profiles.yml does not exist"
    command -v yq >/dev/null || die "packages-evidence: yq is required to read the package profiles"
    yq -o=json '.' "$PROFILES_FILE" >"$profile_json" 2>/dev/null || die "packages-evidence: contracts/package-profiles.yml is not valid YAML"
    while IFS="$SEP" read -r r1 kind_name; do
      kind_roots+=("$r1")
      kind_of[$r1]="$kind_name"
      jq -e --arg k "$kind_name" '.kinds | has($k)' "$profile_json" >/dev/null || die "packages-evidence: the kind '$kind_name' has no entry in contracts/package-profiles.yml"
      required_of[$kind_name]="$(jq -r --arg k "$kind_name" '.kinds[$k].required // [] | .[]' "$profile_json")"
      # a declared root is scanned even when install-dirs does not list it
      pair=" ${scan_roots[*]} "
      [[ $pair == *" $r1 "* ]] || scan_roots+=("$r1")
    done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, .value] | join("\u001f")' <<<"$ROOT_KINDS")
  fi

  local rows=() guard_rows=() manifests=0 declared=0 bad=0
  local root m mdir rel lockjson section name spec problems version origin integrity exact origin_cell integrity_cell status
  local v res_version res_integrity res_tarball link found rkey bin out rc ids line id shown version_cell evidenced=0 prev cdk
  for root in "${scan_roots[@]}"; do
    [[ -d $root ]] || continue
    if ((kinds_mode)); then
      # a directory with CDK files is an IaC root whatever it was declared as (K3): looked up on disk, by file name
      while IFS= read -r -d '' cdk; do cdk="${cdk#./}"; cdk_dirs[$(dirname "$cdk")]=1; done < <(find "$root" \( -name node_modules -o -name .git -o -name cdk.out \) -prune -o -type f -name cdk.json -print0 | sort -z)
    fi
    while IFS= read -r -d '' m; do
      m="${m#./}"
      mdir="$(dirname "$m")"
      if ((kinds_mode)); then
        # each manifest is read once, by the most specific declared root; one outside every declared root is not counted
        [[ -z ${seen_manifest[$m]:-} ]] || continue
        seen_manifest[$m]=1
        kroot="$(longest_root "$mdir" "${kind_roots[@]}")"
        if [[ -z $kroot ]]; then
          ignored=$((ignored + 1))
          continue
        fi
        # its lockfile is the one of the most specific root (install or declared) that contains it AND has a lockfile: a root with its own
        # lockfile resolves its own packages, one without (a workspace member) resolves in the root above. With none, the most specific
        # install root names the lockfile that is missing.
        lock_root=""
        for r1 in "${scan_roots[@]}"; do
          in_root "$mdir" "$r1" && [[ -f $r1/$lock ]] || continue
          if [[ -z $lock_root ]] || (($(root_len "$r1") > $(root_len "$lock_root"))); then lock_root=$r1; fi
        done
        [[ -n $lock_root ]] || lock_root="$(longest_root "$mdir" "${roots[@]}")"
        [[ -n $lock_root ]] || lock_root=$root
      else
        kroot=""
        lock_root=$root
      fi
      lockjson=""
      if [[ -n ${lock_cache[$lock_root]+x} ]]; then
        lockjson="${lock_cache[$lock_root]}"
      else
        if [[ -f $lock_root/$lock ]]; then
          lockjson="$work/lock-${lock_root//\//_}.json"
          if [[ $pm == pnpm ]]; then
            yq -o=json '.' "$lock_root/$lock" >"$lockjson" 2>/dev/null || lockjson="UNREADABLE"
          else
            jq -c '.' "$lock_root/$lock" >"$lockjson" 2>/dev/null || lockjson="UNREADABLE"
          fi
        fi
        lock_cache[$lock_root]="$lockjson"
      fi
      manifests=$((manifests + 1))
      if [[ $mdir == "$lock_root" ]]; then rel="."; else rel="${mdir#"$lock_root"/}"; fi
      if ! jq -e 'type == "object"' "$m" >/dev/null 2>&1; then
        # Not JSON: say so when it mentions a package of ours instead of silently skipping it.
        grep -q '@nextep/' "$m" 2>/dev/null || continue
        declared=$((declared + 1))
        bad=$((bad + 1))
        rows+=("| — | $(code "$m") | — | — | — | — | ❌ the manifest is not valid JSON |")
        continue
      fi
      if ((kinds_mode)) && jq -e '[.dependencies, .devDependencies, .peerDependencies, .optionalDependencies] | map(select(type == "object") | has("aws-cdk-lib")) | any' "$m" >/dev/null 2>&1; then
        cdk_dirs[$mdir]=1
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
          problems+=("no lockfile ($lock_root/$lock)")
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
        if ((kinds_mode)); then
          # what this root declares, for the "Required by kind" table: ok beats problem beats an in-repo package (the same package can be
          # declared in several manifests of the root; one good declaration is the evidence)
          prev="${req_state[$kroot|$name]:-}"
          if ((${#problems[@]} > 0)); then
            [[ $prev == ok ]] || req_state[$kroot|$name]=problem
          elif [[ $exact == workspace ]]; then
            [[ -n $prev ]] || req_state[$kroot|$name]=workspace
          else
            req_state[$kroot|$name]=ok
          fi
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

  # --- required by kind: what each declared kind asks for, against what its root declares (only with root-kinds) -----------------------------
  local kind_rows=() req_bad=0 req_ok=0 req_defined=0 state pkg_name nodel_kinds=() cdir kr
  if ((kinds_mode)); then
    for kroot in "${kind_roots[@]}"; do
      kind_name="${kind_of[$kroot]}"
      if [[ -z ${required_of[$kind_name]} ]]; then
        kind_rows+=("| $(code "$kroot") | $kind_name | — | ➖ no packages are defined for this kind |")
        case " ${nodel_kinds[*]:-} " in *" $kind_name "*) ;; *) nodel_kinds+=("$kind_name") ;; esac
        continue
      fi
      req_defined=$((req_defined + 1))
      while IFS= read -r pkg_name; do
        [[ -n $pkg_name ]] || continue
        state="${req_state[$kroot|$pkg_name]:-}"
        case "$state" in
          ok)
            if [[ -d $kroot/node_modules ]]; then
              req_ok=$((req_ok + 1))
              status="✅ declared and resolved in the lockfile"
            else
              req_bad=$((req_bad + 1))
              status="❌ not installed: $(code "$kroot/node_modules") does not exist"
            fi
            ;;
          problem)
            # the row of the package already counted as a problem; it is repeated here so the screenshot reads without scrolling
            req_bad=$((req_bad + 1))
            status="❌ required by kind $kind_name and declared, but with a problem (see Packages)"
            ;;
          workspace)
            req_bad=$((req_bad + 1))
            status="❌ required by kind $kind_name, but only declared as an in-repo package (not a Release)"
            ;;
          *)
            req_bad=$((req_bad + 1))
            status="❌ required by kind $kind_name and not declared"
            ;;
        esac
        kind_rows+=("| $(code "$kroot") | $kind_name | $(code "$pkg_name") | $status |")
      done <<<"${required_of[$kind_name]}"
    done
    # a directory with CDK files that is not declared iac: declaring another kind must not dodge the IaC standard (K3)
    for cdir in $(printf '%s\n' "${!cdk_dirs[@]}" | sort); do
      kr="$(longest_root "$cdir" "${kind_roots[@]}")"
      if [[ -z $kr ]]; then
        req_bad=$((req_bad + 1))
        kind_rows+=("| $(code "$cdir") | (not declared) | — | ❌ undeclared iac root: it has CDK files and no declared root contains it |")
      elif [[ ${kind_of[$kr]} != iac ]]; then
        req_bad=$((req_bad + 1))
        kind_rows+=("| $(code "$cdir") | ${kind_of[$kr]} (via $(code "$kr")) | — | ❌ undeclared iac root: it has CDK files and is not declared iac |")
      fi
    done
  fi
  # what proves something: the required packages found (root-kinds) or every package evidenced (without it)
  local proof=$evidenced
  ((!kinds_mode)) || proof=$req_ok

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
  # With root-kinds the same rule reads: green only when every package the declared kinds REQUIRE is evidenced (and nothing else is red). A set
  # of kinds that require nothing is n/a with its reason, whatever else the repository declares: a package nobody asked for proves nothing.
  # A required package that is missing, and an undeclared IaC root, are red like any red row (req_bad); none of this ever fails the job.
  local verdict
  if ((bad > 0 || val_bad > 0 || req_bad > 0)); then
    verdict="❌ FAILED"
  elif ((kinds_mode ? req_defined == 0 : evidenced == 0)); then
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
  # The platform that ran: both parts or nothing. A value the context does not have is said so, never printed as `unknown`.
  if [[ -n ${ACTION_REPOSITORY:-} && -n ${ACTION_REF:-} ]]; then
    printf '| Platform | %s |\n' "$(code "${ACTION_REPOSITORY}@${ACTION_REF}")"
  else
    printf '| Platform | not available |\n'
  fi
  if ((kinds_mode)); then
    shown=""
    for kroot in "${kind_roots[@]}"; do shown+="${shown:+, }$(code "$kroot") → ${kind_of[$kroot]}"; done
    printf '| Roots scanned | %s (%s roots, %s package.json%s) |\n\n' "$shown" "${#kind_roots[@]}" "$manifests" \
      "$( ((ignored > 0)) && printf ', %s outside every declared root, not counted' "$ignored" || true)"
    printf '### Required by kind\n\n'
    printf '| Root | Kind | Required package | Status |\n|---|---|---|---|\n'
    printf '%s\n' "${kind_rows[@]}"
    if ((req_defined == 0)); then
      printf '\n**n/a**: the kind(s) %s define no required packages, so there is nothing the standard asks of these roots yet (never a tick).\n' "$(code "$(join_by ', ' "${nodel_kinds[@]}")")"
    fi
    printf '\n'
  else
    printf '| Roots scanned | %s (%s package.json) |\n\n' "$(code "$(join_by ',' "${roots[@]}")")" "$manifests"
  fi

  if ((declared == 0)); then
    if ((kinds_mode)); then
      # the verdict is decided by the table above, not by this section: it must not read like one
      printf '### Packages\n\nNone of the %s package.json file(s) of the declared roots declares a %s dependency.\n\n' "$manifests" "$(code '@nextep/*')"
    else
      printf '### Packages\n\n**n/a**: none of the %s package.json file(s) declares a %s dependency, so there is no package evidence to show.\n\n' "$manifests" "$(code '@nextep/*')"
    fi
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
      if ((proof == 0)) && [[ $mark == "✅ passed" ]]; then mark="➖ passed (no packages to evidence)"; fi
      printf '| %s | %s |\n' "$(code "${val_labels[$i]}")" "$mark"
    done
  fi
  if ((bad > 0 || val_bad > 0 || req_bad > 0)); then printf '\n%s\n' "$NOT_GREEN_MARKER"; fi
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
