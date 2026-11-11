# shellcheck shell=bash
# Shared helpers. Source it: `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"`.
# Nothing here prints a secret: callers pass values through `mask` BEFORE their first use.

log() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*" >&2; }
die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# mask <value>: registers the value so the runner redacts it from every later log line.
mask() { [[ -z ${1:-} ]] || printf '::add-mask::%s\n' "$1"; }

# require_env VAR...: dies naming every missing variable.
require_env() {
  local v missing=()
  for v in "$@"; do [[ -n ${!v:-} ]] || missing+=("$v"); done
  ((${#missing[@]} == 0)) || die "missing required environment variable(s): ${missing[*]}"
}

# stage_of <dev|stg|prod> -> Dev|Stg|Prod
stage_of() {
  case "$1" in
    dev) printf 'Dev' ;;
    stg) printf 'Stg' ;;
    prod) printf 'Prod' ;;
    *) return 1 ;;
  esac
}

# input_env <input-name> -> value of INPUT_<NAME> (dashes become underscores, upper case)
input_env() {
  local n="${1^^}"
  n="INPUT_${n//-/_}"
  printf '%s' "${!n:-}"
}

# urlencode <string>: percent-encodes every byte except [A-Za-z0-9.~_-].
urlencode() {
  local LC_ALL=C s=$1 i c out=''
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c" && out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# download_verified <url> <sha256> <outfile>: downloads and refuses anything whose sha256 differs.
download_verified() {
  local url=$1 sha=$2 out=$3
  curl --fail --silent --show-error --location --retry 3 --output "$out" "$url" || die "download failed: $url"
  if ! printf '%s  %s\n' "$sha" "$out" | sha256sum --check --status; then
    rm -f "$out"
    die "sha256 mismatch for $url (expected $sha)"
  fi
}

# retry <attempts> <delay-seconds> cmd...
retry() {
  local attempts=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    "$@" && return 0
    ((i == attempts)) || sleep "$delay"
  done
  return 1
}
