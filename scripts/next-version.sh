#!/usr/bin/env bash
# Decides WHETHER there is something to release and WHICH version it gets (a pure function over the git repo of the cwd).
#   next-version.sh [--bump auto|patch|minor] [--version X.Y.Z]
#   next-version.sh --print-non-surface        # the non-surface list, one pattern per line
#   next-version.sh --classify                 # NUL-separated paths on stdin -> "surface<TAB>path" | "non-surface<TAB>path<TAB>pattern"
#
# stdout (machine, key=value, ready for $GITHUB_OUTPUT): release=true|false, last, base, next, level.
# $NEXT_VERSION_REPORT (a file path): human report in markdown, written on success AND on failure. Unset = no report.
# stderr: the reason of every failure, plain text. Exit != 0 on any error.
#
# Rules (the spec lives in the private design repository; the invariants are enforced by test/bats/next-version.bats
# and test/gates/release-auto.bats):
#   - last release = highest tag vX.Y.Z (by version, not by text); other tags are ignored;
#   - the commit of that tag must have exactly one parent and the canonical subject written by release.yml; its parent is the
#     BASE (the release commit is not in the history of main);
#   - what counts as "something to release" is every versioned path EXCEPT the non-surface list below;
#   - the level is the highest of: the mechanical floor from contracts/*.contract.yml, the commit types and --bump;
#   - `auto` never produces a major: that needs an explicit --version.
# Commit subjects and bodies are UNTRUSTED input: they are only read as data, never evaluated, and they are neutralised
# before they reach the report.
set -euo pipefail

# Non-surface paths, declared TWICE: here and in docs/release-surface.yml (with the reason of each). Gate RA7 fails if the two
# lists differ or if an entry matches no versioned file. `dir/**` = everything under dir; a pattern with no `/` matches the
# root only; anything else is an exact path. Everything NOT listed is surface: a new file must trigger a release by default.
NON_SURFACE=(
  'docs/**'
  'test/**'
  '*.md'
  '.gitattributes'
  '.github/CODEOWNERS'
  '.github/workflows/release.yml'
  '.github/workflows/self-ci.yml'
  'scripts/release.sh'
  'scripts/next-version.sh'
  'scripts/ci/**'
  'scripts/lib/tools.env'
)

fail() {
  printf 'next-version: %s\n' "$*" >&2
  exit 1
}

# matching_pattern <path>: prints the non-surface pattern that matches and returns 0; returns 1 when the path is surface.
matching_pattern() {
  local p=$1 pat
  for pat in "${NON_SURFACE[@]}"; do
    if [[ $pat == */'**' ]]; then
      [[ $p == "${pat%'**'}"* ]] || continue
    elif [[ $pat == */* ]]; then
      [[ $p == "$pat" ]] || continue
    else
      # shellcheck disable=SC2053 # the glob on the right is the point
      [[ $p != */* && $p == $pat ]] || continue
    fi
    printf '%s' "$pat"
    return 0
  done
  return 1
}

# sanitize <untrusted one-liner>: safe for a markdown list and for a log: no control characters, no workflow commands (`::`),
# no markup that could close or open anything.
sanitize() {
  local s=${1//$'\r'/ }
  s=$(printf '%s' "$s" | tr -d '\000-\010\013-\037\177')
  while [[ $s == *'::'* ]]; do s=${s//::/: :}; done
  s=${s//\`/\'}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//|/\\|}
  printf '%s' "${s:0:200}"
}

level_rank() {
  case $1 in
    patch) echo 1 ;;
    minor) echo 2 ;;
    major) echo 3 ;;
    *) fail "internal: unknown level '$1'" ;;
  esac
}
rank_level() { case $1 in 1) echo patch ;; 2) echo minor ;; *) echo major ;; esac; }

# ver_gt <a> <b>: a > b as versions (X.Y.Z, no v).
ver_gt() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }

# --- arguments ---------------------------------------------------------------------------------------------------------------
bump=auto
version=''
while (($#)); do
  case $1 in
    --bump)
      [[ $# -ge 2 ]] || fail "--bump needs a value (auto, patch or minor)"
      bump=$2
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version needs a value (X.Y.Z)"
      version=$2
      shift 2
      ;;
    --print-non-surface)
      printf '%s\n' "${NON_SURFACE[@]}"
      exit 0
      ;;
    --classify)
      while IFS= read -r -d '' p; do
        if pat=$(matching_pattern "$p"); then printf 'non-surface\t%s\t%s\n' "$p" "$pat"; else printf 'surface\t%s\n' "$p"; fi
      done
      exit 0
      ;;
    *) fail "unknown argument '$(sanitize "$1")' (usage: next-version.sh [--bump auto|patch|minor] [--version X.Y.Z])" ;;
  esac
done
case $bump in auto | patch | minor) ;; *) fail "--bump must be auto, patch or minor (got '$(sanitize "$bump")'): a major is never automatic, pass --version" ;; esac
if [[ -n $version ]]; then
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version must be X.Y.Z (got '$(sanitize "$version")')"
  [[ $bump == auto ]] || fail "--version and --bump are mutually exclusive: an explicit version needs --bump auto"
fi
for t in git yq jq; do command -v "$t" >/dev/null 2>&1 || fail "required tool '$t' is not installed"; done
git rev-parse --git-dir >/dev/null 2>&1 || fail "not inside a git repository"

# --- report (written on every exit, success or failure) ------------------------------------------------------------------------
REPORT=()
report() { REPORT+=("$1"); }
write_report() {
  [[ -n ${NEXT_VERSION_REPORT:-} ]] || return 0
  ((${#REPORT[@]} > 0)) || return 0
  printf '%s\n' "${REPORT[@]}" >"$NEXT_VERSION_REPORT"
}
trap write_report EXIT
report "## Release plan"

# --- discovery (RA12): a decision over nothing proves nothing -----------------------------------------------------------------
git rev-parse --verify --quiet HEAD >/dev/null || fail "the repository has no commits"
head_sha=$(git rev-parse HEAD)

surface_total=0
while IFS= read -r -d '' f; do
  matching_pattern "$f" >/dev/null || surface_total=$((surface_total + 1))
done < <(git ls-tree -r -z --name-only HEAD)
((surface_total > 0)) || fail "0 surface files discovered at HEAD: every path matches the non-surface list (a decision over nothing proves nothing)"

contracts_head=()
while IFS= read -r -d '' f; do
  [[ $f == contracts/*.contract.yml ]] && contracts_head+=("$f")
done < <(git ls-tree -z --name-only HEAD contracts/)
((${#contracts_head[@]} > 0)) || fail "0 contracts discovered under contracts/ at HEAD: the public API cannot be compared (a decision over nothing proves nothing)"

# --- 1. last release ---------------------------------------------------------------------------------------------------------
last_tag=$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)

if [[ -n $version ]]; then
  if git rev-parse --verify --quiet "refs/tags/v${version}" >/dev/null; then
    fail "v${version} already exists: a published tag is never moved or deleted; cut a new version"
  fi
  if [[ -n $last_tag ]]; then
    ver_gt "$version" "${last_tag#v}" ||
      fail "version ${version} is not greater than the last release ${last_tag}: the alias vX only moves forward, never back"
  fi
fi

if [[ -z $last_tag ]]; then
  [[ -n $version ]] || fail "there is no release tag yet: the first release needs an explicit --version"
  report "- first release: no previous tag, nothing to compare; version **${version}** (explicit)"
  report ""
  report "Next version: **v${version}**"
  printf 'release=true\nlast=\nbase=\nnext=%s\nlevel=initial\n' "$version"
  exit 0
fi
last=${last_tag#v}

# --- 2. integrity of the tag ---------------------------------------------------------------------------------------------------
tag_commit=$(git rev-parse --verify --quiet "refs/tags/${last_tag}^{commit}") || fail "cannot resolve ${last_tag} to a commit"
read -r -a parents < <(git rev-list --parents -n1 "$tag_commit")
((${#parents[@]} == 2)) ||
  fail "${last_tag} is anomalous: its commit must have exactly one parent (it has $((${#parents[@]} - 1))). A tag that was not born in release.yml makes the comparison base false"
base=${parents[1]}
tag_subject=$(git log -1 --format=%s "$tag_commit")
expected="release: ${last_tag} (internal references pinned to ${base})"
[[ $tag_subject == "$expected" ]] ||
  fail "${last_tag} is anomalous: its commit subject is not the canonical '${expected}' (got '$(sanitize "$tag_subject")'). A tag that was not born in release.yml makes the comparison base false"
git cat-file -e "${base}^{commit}" 2>/dev/null || fail "the base commit ${base} of ${last_tag} is not in this clone (fetch the full history)"
git merge-base --is-ancestor "$base" "$head_sha" ||
  fail "the base ${base} of ${last_tag} is not an ancestor of HEAD: the history was rewritten after the release"

report ""
report "- last release: **${last_tag}** (base \`${base:0:12}\`, HEAD \`${head_sha:0:12}\`)"

# --- 3. is there anything to release? -------------------------------------------------------------------------------------------
surface_changed=()
while IFS= read -r -d '' f; do
  matching_pattern "$f" >/dev/null || surface_changed+=("$f")
done < <(git diff --name-only --no-renames -z "$base" "$head_sha")

if ((${#surface_changed[@]} == 0)); then
  report "- nothing to release: no surface file changed since the base"
  printf 'release=false\nlast=%s\nbase=%s\nnext=\nlevel=\n' "$last" "$base"
  exit 0
fi
report "- surface files changed since the base: ${#surface_changed[@]}"

# --- 4. mechanical floor from the contracts ------------------------------------------------------------------------------------
# contract_json <rev> <path>: the contract as JSON, or "null" when the file does not exist at that revision.
contract_json() {
  if git cat-file -e "$1:$2" 2>/dev/null; then git show "$1:$2" | yq -o=json '.'; else printf 'null'; fi
}

contracts_all=("${contracts_head[@]}")
while IFS= read -r -d '' f; do
  [[ $f == contracts/*.contract.yml ]] || continue
  [[ " ${contracts_all[*]} " == *" $f "* ]] || contracts_all+=("$f")
done < <(git ls-tree -z --name-only "$base" contracts/)

# shellcheck disable=SC2016 # jq program, not shell
DIFF_JQ='
def inputs: (.inputs // {}) | map_values(. // {} | {type: .type, required: (.required // false), has_default: has("default"), default: (if has("default") then .default else null end)});
def secrets: (.secrets // {}) | map_values({required: ((. // {}).required // false)});
def outs: (.outputs // {}) | keys;
def jobs: (.jobs // []);
(($b | inputs) as $bi | ($h | inputs) as $hi |
  [ ($bi | keys[]) | select($hi[.] == null) | ["major", "input removed or renamed: \(.)"] ] +
  [ ($hi | keys[]) | select($bi[.] == null) | . as $k |
      if ($hi[$k].required and ($hi[$k].has_default | not)) then ["major", "new required input without a default: \($k)"]
      else ["minor", "new optional input: \($k)"] end ] +
  [ ($bi | keys[]) | select($hi[.] != null) | . as $k | $bi[$k] as $x | $hi[$k] as $y |
      (if $x.type != $y.type then ["major", "input type changed: \($k) (\($x.type) -> \($y.type))"] else empty end),
      (if ($x.required | not) and $y.required then ["major", "input became required: \($k)"] else empty end),
      (if $x.default != $y.default then ["minor", "input default changed: \($k)"] else empty end) ]
) +
(($b | secrets) as $bs | ($h | secrets) as $hs |
  [ ($bs | keys[]) | select($hs[.] == null) | ["major", "secret removed or renamed: \(.)"] ] +
  [ ($hs | keys[]) | select($bs[.] == null) | . as $k |
      if $hs[$k].required then ["major", "new required secret: \($k)"] else ["minor", "new optional secret: \($k)"] end ] +
  [ ($bs | keys[]) | select($hs[.] != null) | . as $k | select(($bs[$k].required | not) and $hs[$k].required) | ["major", "secret became required: \($k)"] ]
) +
(($b | outs) as $bo | ($h | outs) as $ho |
  [ ($bo - $ho)[] | ["major", "output removed or renamed: \(.)"] ] + [ ($ho - $bo)[] | ["minor", "new output: \(.)"] ]
) +
(($b | jobs) as $bj | ($h | jobs) as $hj |
  [ ($bj - $hj)[] | ["major", "job removed or renamed (breaks the required checks of every caller): \(.)"] ] + [ ($hj - $bj)[] | ["minor", "new job: \(.)"] ]
) | .[] | "\(.[0])\t\(.[1])"'

floor_rank=1
major_findings=()
floor_lines=()
for f in "${contracts_all[@]}"; do
  b_json=$(contract_json "$base" "$f")
  h_json=$(contract_json "$head_sha" "$f")
  if [[ $b_json == null ]]; then
    floor_lines+=("minor"$'\t'"$f: new contract")
    continue
  fi
  if [[ $h_json == null ]]; then
    floor_lines+=("major"$'\t'"$f: contract deleted")
    continue
  fi
  while IFS= read -r line; do
    [[ -n $line ]] && floor_lines+=("${line%%$'\t'*}"$'\t'"$f: ${line#*$'\t'}")
  done < <(jq -rn --argjson b "$b_json" --argjson h "$h_json" "$DIFF_JQ")
done
# a workflow deleted from the tree is a major even if its contract was left behind
while IFS= read -r -d '' f; do
  [[ $f == .github/workflows/lego-*.yml ]] || continue
  git cat-file -e "$head_sha:$f" 2>/dev/null || floor_lines+=("major"$'\t'"$f: workflow deleted")
done < <(git ls-tree -z --name-only "$base" .github/workflows/)

report ""
report "### Contract changes (mechanical floor)"
if ((${#floor_lines[@]} == 0)); then
  report "- none"
else
  for line in "${floor_lines[@]}"; do
    lv=${line%%$'\t'*}
    msg=${line#*$'\t'}
    report "- **${lv}**: $(sanitize "$msg")"
    r=$(level_rank "$lv")
    ((r <= floor_rank)) || floor_rank=$r
    [[ $lv == major ]] && major_findings+=("$msg")
  done
fi

# --- 5. level from the commits that touch the surface --------------------------------------------------------------------------
commit_rank=1
commit_lines=()
warnings=()
type_re='^([A-Za-z]+)(\([^)]*\))?(!)?:[[:space:]]'
break_re=$'(^|\n)BREAKING[ -]CHANGE:'
while IFS= read -r sha; do
  [[ -n $sha ]] || continue
  touches=0
  while IFS= read -r -d '' f; do
    matching_pattern "$f" >/dev/null || { touches=1; break; }
  done < <(git diff-tree --root --no-commit-id --name-only --no-renames -r -z "$sha")
  ((touches == 1)) || continue
  subj=$(git log -1 --format=%s "$sha")
  body=$(git log -1 --format=%b "$sha")
  lv="patch"
  if [[ $subj =~ $type_re ]]; then
    ctype=${BASH_REMATCH[1],,}
    bang=${BASH_REMATCH[3]}
    case $ctype in
      feat) lv="minor" ;;
      fix | ref | infra | chore | docs) lv="patch" ;;
      *)
        lv="patch"
        warnings+=("unrecognised commit type '$(sanitize "$ctype")' in ${sha:0:12} (counted as patch): $(sanitize "$subj")")
        ;;
    esac
    [[ -z $bang ]] || { lv="major"; major_findings+=("breaking commit ${sha:0:12}: $subj"); }
  else
    warnings+=("no recognised type prefix in ${sha:0:12} (counted as patch): $(sanitize "$subj")")
  fi
  if [[ $body =~ $break_re ]]; then
    lv="major"
    major_findings+=("BREAKING CHANGE footer in ${sha:0:12}: $subj")
  fi
  commit_lines+=("${lv}"$'\t'"${sha:0:12}"$'\t'"$subj")
  r=$(level_rank "$lv")
  ((r <= commit_rank)) || commit_rank=$r
done < <(git log --no-merges --format=%H "${base}..${head_sha}")

report ""
report "### Commits that touch the release surface (${#commit_lines[@]})"
if ((${#commit_lines[@]} == 0)); then
  report "- none (the surface changed only through merge commits)"
else
  for line in "${commit_lines[@]}"; do
    IFS=$'\t' read -r lv short subj <<<"$line"
    report "- **${lv}** \`${short}\` $(sanitize "$subj")"
  done
fi
if ((${#warnings[@]} > 0)); then
  report ""
  report "### Warnings"
  for w in "${warnings[@]}"; do report "- $w"; done
fi

# --- 6. final level ------------------------------------------------------------------------------------------------------------
bump_rank=1
[[ $bump == auto ]] || bump_rank=$(level_rank "$bump")
if [[ $bump != auto ]] && ((bump_rank < floor_rank)); then
  report ""
  report "**Error:** --bump ${bump} is below the mechanical floor (${floor_rank})"
  fail "--bump ${bump} is below the mechanical floor $(rank_level "$floor_rank") that the contracts impose: $(sanitize "${floor_lines[*]//$'\t'/ }"). Use --bump $(rank_level "$floor_rank") or auto"
fi
final_rank=$floor_rank
((commit_rank <= final_rank)) || final_rank=$commit_rank
((bump_rank <= final_rank)) || final_rank=$bump_rank
level=$(rank_level "$final_rank")

# --- 7/8. the version ----------------------------------------------------------------------------------------------------------
IFS=. read -r l_major l_minor l_patch <<<"$last"
if [[ -n $version ]]; then
  next=$version
  IFS=. read -r n_major n_minor _ <<<"$next"
  if ((n_major > l_major)); then implied="major"; elif ((n_minor > l_minor)); then implied="minor"; else implied="patch"; fi
  if (($(level_rank "$implied") < final_rank)); then
    report ""
    report "- warning: the explicit version ${next} is a ${implied} over ${last} but the changes compute a ${level}"
  fi
  level=$implied
else
  if [[ $level == major ]]; then
    report ""
    report "**Error:** the changes are incompatible; \`auto\` never produces a major"
    for m in "${major_findings[@]}"; do report "- $(sanitize "$m")"; done
    detail=''
    for m in "${major_findings[@]}"; do detail+=$'\n  - '"$(sanitize "$m")"; done
    fail "the changes since ${last_tag} include an incompatible one and \`auto\` never produces a major:${detail}
To proceed: pass an explicit --version (the next major) AND update the trust policies of every account (they list refs/tags/v<major>) before anyone pins the new major"
  fi
  case $level in
    minor) next="${l_major}.$((l_minor + 1)).0" ;;
    patch) next="${l_major}.${l_minor}.$((l_patch + 1))" ;;
  esac
  git rev-parse --verify --quiet "refs/tags/v${next}" >/dev/null && fail "v${next} already exists: a published tag is never moved or deleted"
fi

report ""
report "- level: **${level}**"
report "- next version: **v${next}**"
printf 'release=true\nlast=%s\nbase=%s\nnext=%s\nlevel=%s\n' "$last" "$base" "$next" "$level"
