#!/usr/bin/env bash
# G13 detector: this repository is PUBLIC. Scans the tracked/untracked-not-ignored files of <root>.
# Prints "<file>:<line>: <detector>" (never the matched value) and exits 1 when something is found.
# Exit 2: no files to scan. Env: INTERNAL_DENYLIST (newline/comma separated internal names),
# GATE_REQUIRE_DENYLIST=1 (fail when INTERNAL_DENYLIST is empty).
set -euo pipefail

root="${1:?usage: scan-public.sh <root>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
domains_file="$here/public-domains.txt"

cd "$root"
files=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ "$(git rev-parse --show-toplevel)" == "$(pwd -P)" ]]; then
  while IFS= read -r -d '' f; do [[ -f $f ]] && files+=("$f"); done < <(git ls-files -co --exclude-standard -z)
else
  while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(find . -type f -not -path './.git/*' -not -path '*/node_modules/*' -print0)
fi

if ((${#files[@]} == 0)); then
  echo "G13: 0 files to scan under $root (a gate that finds nothing proves nothing)" >&2
  exit 2
fi

found=0
hit() {
  echo "$1:$2: $3"
  found=1
}

mapfile -t allowed < <(grep -Ev '^\s*(#|$)' "$domains_file")
host_allowed() {
  local h=$1 p
  for p in "${allowed[@]}"; do [[ $h =~ ^${p}$ ]] && return 0; done
  return 1
}

denylist="$(mktemp)"
trap 'rm -f "$denylist"' EXIT
printf '%s\n' "${INTERNAL_DENYLIST:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' >"$denylist" || true
if [[ ! -s $denylist ]]; then
  if [[ "${GATE_REQUIRE_DENYLIST:-}" == "1" ]]; then
    echo "G13: INTERNAL_DENYLIST is not configured (organization secret); the gate cannot vouch for internal names" >&2
    exit 1
  fi
  echo "G13: INTERNAL_DENYLIST not set; running only the generic detectors" >&2
fi

email_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
ip_re='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'

for f in "${files[@]}"; do
  grep -Iq . "$f" 2>/dev/null || continue # skip binary and empty files
  while IFS=: read -r n _; do hit "$f" "$n" "12-digit cloud account id"; done \
    < <(grep -nE '(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)' "$f" || true)
  while IFS=: read -r n _; do hit "$f" "$n" "arn with a literal account id"; done \
    < <(grep -nE 'arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' "$f" || true)
  while IFS=: read -r n line; do
    while IFS= read -r email; do
      [[ $email =~ @example\.[a-z]+$ ]] || hit "$f" "$n" "email address"
    done < <(grep -oE "$email_re" <<<"$line")
  done < <(grep -nE "$email_re" "$f" || true)
  while IFS=: read -r n _; do hit "$f" "$n" "private IP address"; done \
    < <(grep -nE "$ip_re" "$f" || true)
  while IFS=: read -r n line; do
    while IFS= read -r url; do
      host="${url#*://}"
      host="${host%%[/:?#\"\')> \\]*}"
      [[ -z $host || $host == *'<'* || $host == *'$'* || $host == *'{'* || $host == *'%'* ]] && continue
      host_allowed "$host" || hit "$f" "$n" "URL host outside the public allowlist"
    done < <(grep -oE 'https?://[^[:space:]]+' <<<"$line")
  done < <(grep -nE 'https?://' "$f" || true)
  if [[ -s $denylist ]]; then
    while IFS=: read -r n _; do hit "$f" "$n" "internal name from INTERNAL_DENYLIST"; done \
      < <(grep -niFf "$denylist" "$f" || true)
  fi
done

exit "$found"
