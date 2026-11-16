#!/usr/bin/env bash
# Python dependencies of the project (input python-requirements: comma separated relative paths, in install order).
#   python-install.sh      validates EVERY requirements file, then installs each one with pip, in order
# Env: PYTHON_REQUIREMENTS (required). Runs from the repository root (GITHUB_WORKSPACE, default: the current directory).
#
# This is the pip counterpart of `--frozen-lockfile`: two runs of the same commit must install the same thing. So the files
# are validated BEFORE anything is installed, and only pinned requirements are accepted:
#   accepted  comments, blank lines, `-r <file>` / `-c <file>` (relative, inside the repository, at most 3 levels deep, also
#             validated), `name==version` (extras and environment markers allowed) and `--hash=<alg>:<hex>` options;
#   rejected  ranges (>= <= ~= != > < and wildcards), requirements without a version, -e, URLs and VCS requirements,
#             package source options (--index-url, --extra-index-url, --find-links, --trusted-host: the classic
#             dependency-confusion vector) and every other option.
# When a file carries hashes pip enforces them by itself (require-hashes mode). No venv: the runner is ephemeral.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MAX_DEPTH=3
range_re='>=|<=|~=|!=|>|<|==[^=]*[*]|==='
root="$(cd "${GITHUB_WORKSPACE:-$PWD}" && pwd -P)"
errs=()
err() { errs+=("$*"); }

# A path as written in python-requirements (same rules as install-dirs, plus: no '.', must be a file).
valid_top_path() {
  [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] && [[ $1 != *..* ]] && [[ $1 != */ ]]
}

[[ -n ${PYTHON_REQUIREMENTS:-} ]] || die "python-install: PYTHON_REQUIREMENTS is empty (python-requirements is required with python-version)"
IFS=',' read -r -a top <<<"$PYTHON_REQUIREMENTS"
for f in "${top[@]}"; do
  valid_top_path "$f" || die "python-install: invalid requirements path '$f' (relative path to a file, no '..', no spaces, no trailing '/')"
done

# resolve_nested <from-file> <path as written>: prints the repository-relative path; on failure prints the reason and returns 1.
resolve_nested() {
  local from=$1 path=$2 abs
  if [[ ! $path =~ ^[A-Za-z0-9_.][A-Za-z0-9._/-]*$ || $path == */ || $path == *//* ]]; then
    printf "the path '%s' is not a plain relative path (no absolute paths, spaces or special characters)" "$path"
    return 1
  fi
  abs="$(realpath -m -- "$root/$(dirname "$from")/$path")"
  if [[ $abs != "$root"/* ]]; then
    printf "'%s' points outside the repository" "$path"
    return 1
  fi
  printf '%s' "${abs#"$root"/}"
}

# check_file <repo-relative file> <depth> <chain: files already open, separated by newlines>
check_file() {
  local file=$1 depth=$2 chain=$3
  if [[ ! -f $root/$file ]]; then
    err "$file: requirements file not found"
    return 0
  fi
  local lineno=0 start=0 logical="" raw text
  while IFS= read -r raw || [[ -n $raw ]]; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    ((${#logical} > 0)) || start=$lineno
    if [[ $raw == *\\ ]]; then
      logical+="${raw%\\} "
      continue
    fi
    text="$logical$raw"
    logical=""
    check_line "$file" "$start" "$text" "$depth" "$chain"
  done <"$root/$file"
  if [[ -n $logical ]]; then check_line "$file" "$start" "$logical" "$depth" "$chain"; fi
}

check_line() {
  local file=$1 text=$3 depth=$4 chain=$5 where="$1:$2" body pre spec marker hashes opt rest nested
  # comments: a line starting with '#', or '#' preceded by whitespace
  body="$(sed -E 's/^[[:space:]]+//; /^#/d; s/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$text")"
  [[ -n $body ]] || return 0

  if [[ $body == -* ]]; then
    opt="${body%%[[:space:]=]*}"
    rest="${body#"$opt"}"
    rest="${rest#"${rest%%[![:space:]=]*}"}"
    case "$opt" in
      -r | --requirement | -c | --constraint)
        if [[ -z $rest ]]; then
          err "$where: '$opt' needs a file"
          return 0
        fi
        if ((depth + 1 > MAX_DEPTH)); then
          err "$where: '$opt $rest' nests deeper than $MAX_DEPTH levels (flatten the files)"
          return 0
        fi
        if ! nested="$(resolve_nested "$file" "$rest")"; then
          err "$where: $nested"
          return 0
        fi
        if [[ ! -f $root/$nested ]]; then
          err "$where: '$opt $rest' not found ($nested)"
          return 0
        fi
        if grep -qxF -- "$nested" <<<"$chain"; then
          err "$where: '$opt $rest' closes a cycle ($nested is already being read)"
          return 0
        fi
        check_file "$nested" $((depth + 1)) "$chain"$'\n'"$nested"
        ;;
      -e | --editable) err "$where: editable install ($opt) is not allowed: it is not a pinned release" ;;
      --index-url | -i | --extra-index-url | --find-links | -f | --trusted-host | --no-index)
        err "$where: package source option '$opt' is not allowed (dependency confusion vector: the index is the runner's pip configuration)"
        ;;
      *) err "$where: unsupported option '$opt' (only -r, -c and per-requirement --hash are accepted)" ;;
    esac
    return 0
  fi

  # requirements: URL / VCS / direct references first (they would otherwise look like a range or an unversioned name)
  pre="${body%%;*}"
  if [[ $body == *"://"* || $body == git+* || $body == hg+* || $body == svn+* || $body == bzr+* || $pre == *@* ]]; then
    err "$where: URL or VCS requirement is not allowed: '${body%%[[:space:]]--hash*}'"
    return 0
  fi

  # --hash options (they come last, possibly several): validate and strip them
  hashes="$(grep -oE -- '--hash(=|[[:space:]]+)[^[:space:]]*' <<<"$body" || true)"
  if [[ -n $hashes ]]; then
    while IFS= read -r opt; do
      opt="${opt#--hash}"
      opt="${opt#=}"
      opt="${opt#"${opt%%[![:space:]]*}"}"
      [[ $opt =~ ^(sha256:[0-9a-f]{64}|sha384:[0-9a-f]{96}|sha512:[0-9a-f]{128})$ ]] ||
        err "$where: malformed hash '--hash=$opt' (expected sha256:<64 hex>, sha384:<96 hex> or sha512:<128 hex>)"
    done <<<"$hashes"
    body="$(sed -E 's/[[:space:]]*--hash(=|[[:space:]]+)[^[:space:]]*//g' <<<"$body")"
  fi
  if [[ $body == *--* ]]; then
    err "$where: unsupported per-requirement option in '$body' (only --hash is accepted)"
    return 0
  fi

  # split the environment marker: a comparison inside it is not a range
  spec="${body%%;*}"
  marker=""
  [[ $body == *";"* ]] && marker="${body#*;}"
  : "$marker"
  spec="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$spec")"

  if [[ $spec =~ $range_re ]] || [[ $spec == *,* ]]; then
    err "$where: range specifier is not allowed, pin the version with '==' (got '$spec')"
    return 0
  fi
  if [[ $spec != *"=="* ]]; then
    err "$where: requirement has no version, pin it with '==' (got '$spec')"
    return 0
  fi
  if ! [[ $spec =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?([[:space:]]*\[[A-Za-z0-9,._[:space:]-]+\])?[[:space:]]*==[[:space:]]*[A-Za-z0-9][A-Za-z0-9.+!_-]*$ ]]; then
    err "$where: not a valid pinned requirement 'name==version' (got '$spec')"
  fi
}

for f in "${top[@]}"; do
  if [[ ! -f $root/$f ]]; then
    err "$f: requirements file not found (python-requirements must list files)"
    continue
  fi
  check_file "$f" 0 "$f"
done

if ((${#errs[@]} > 0)); then
  for e in "${errs[@]}"; do printf '::error title=Invalid requirements::python-install: %s\n' "$e" >&2; done
  exit 1
fi

for f in "${top[@]}"; do
  log "::group::pip install -r ${f}"
  (cd "$root" && python -m pip install --no-input --disable-pip-version-check -r "$f")
  log "::endgroup::"
done
