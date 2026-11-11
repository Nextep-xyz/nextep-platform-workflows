#!/usr/bin/env bash
# Builds the tree of a release (SPEC D3, gate G11): a copy of the source tree where the internal references of the
# reusable workflows (`Nextep-xyz/nextep-platform-workflows/.github/actions/<x>@main`) point to the SOURCE commit.
#   release.sh <source-sha> <out-dir> [<source-tree>]
# The composites at <source-sha> contain no internal references (gate G11), so pinning to that commit is closed:
# nothing at the end of the chain resolves to a mutable ref. The check is done on disk over the OUTPUT tree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

sha="${1:?usage: release.sh <source-sha> <out-dir> [<source-tree>]}"
out="${2:?usage: release.sh <source-sha> <out-dir> [<source-tree>]}"
src="${3:-$(cd "$here/.." && pwd)}"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "release: <source-sha> must be a full 40-hex commit sha (got '$sha')"
[[ -d $src/.github ]] || die "release: '$src' has no .github directory"

repo_re='Nextep-xyz/nextep-platform-workflows/\.github/(actions|workflows)/[A-Za-z0-9._/-]+'

rm -rf "$out"
mkdir -p "$out"
(cd "$src" && tar --exclude=.git --exclude=node_modules -cf - .) | (cd "$out" && tar -xf -)

mapfile -d '' workflows < <(cd "$out" && find .github/workflows -maxdepth 1 -type f -name 'lego-*.yml' -print0 | sort -z)
((${#workflows[@]} > 0)) || die "release: 0 workflows discovered in $out/.github/workflows (a release of nothing proves nothing)"
for f in "${workflows[@]}"; do
  sed -E -i "s#(${repo_re})@main#\1@${sha}#g" "$out/$f"
done

# Verification on disk, over the output: no internal reference may remain on a mutable ref, in workflows or composites
# (commented lines, such as the DORA placeholder, are not references).
bad=0
while IFS= read -r line; do
  printf '::error::release: unpinned internal reference left in the output: %s\n' "$line" >&2
  bad=1
done < <(cd "$out" && grep -rnE "${repo_re}@" .github --include='*.yml' --include='*.yaml' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE "@[0-9a-f]{40}([^0-9a-f]|\$)" || true)
((bad == 0)) || exit 1
log "release tree ready in $out (internal references pinned to $sha)"
