#!/usr/bin/env bash
# Package roots of the project (P2-D8, input install-dirs: comma separated relative paths, default ".").
#   install-dirs.sh lockfiles   prints the lockfile of every root, one per line (for the setup-node cache key)
#   install-dirs.sh install     runs the immutable install in every root (pnpm install --frozen-lockfile | npm ci)
# Env: INSTALL_DIRS (default ".") PACKAGE_MANAGER (npm | pnpm). The directories were validated by validate-inputs.sh;
# they are checked again here because this script is also the last stop before `cd`.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mode="${1:?usage: install-dirs.sh <lockfiles|install>}"
pm="${PACKAGE_MANAGER:-pnpm}"
case "$pm" in pnpm) lock=pnpm-lock.yaml ;; npm) lock=package-lock.json ;; *) die "install-dirs: package-manager must be npm or pnpm (got '$pm')" ;; esac

IFS=',' read -r -a dirs <<<"${INSTALL_DIRS:-.}"
((${#dirs[@]} > 0)) || die "install-dirs: no directory given"
for d in "${dirs[@]}"; do
  if [[ $d != . && ! $d =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || [[ $d == *..* ]] || [[ $d == */ ]]; then
    die "install-dirs: invalid directory '$d' (relative path, no '..', no spaces)"
  fi
done

case "$mode" in
  lockfiles)
    for d in "${dirs[@]}"; do
      [[ $d == . ]] && printf '%s\n' "$lock" || printf '%s/%s\n' "$d" "$lock"
    done
    ;;
  install)
    for d in "${dirs[@]}"; do
      [[ -f $d/package.json ]] || die "install-dirs: '$d' has no package.json"
      [[ -f $d/$lock ]] || die "install-dirs: '$d' has no $lock (an immutable install needs the lockfile)"
      log "::group::install ${d}"
      if [[ $pm == pnpm ]]; then
        (cd "$d" && pnpm install --frozen-lockfile)
      else
        (cd "$d" && npm ci)
      fi
      log "::endgroup::"
    done
    ;;
  *) die "install-dirs: unknown mode '$mode'" ;;
esac
