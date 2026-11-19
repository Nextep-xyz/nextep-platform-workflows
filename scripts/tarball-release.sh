#!/usr/bin/env bash
# Logic of lego-package-release: a package is distributed as the tarball of a GitHub Release (no registry). One subcommand per step.
#   tarball-release.sh check    (gate)    shape of the inputs and of the triggering ref; tag == <tag-prefix><package.json version>
#   tarball-release.sh pack     (gate)    `npm pack` ONCE, review of THAT tarball, sha256; the bytes reviewed are the bytes released
#   tarball-release.sh create   (release) refuses an existing Release, creates it with the tarball and the .sha256 (never --clobber)
#   tarball-release.sh verify   (release) downloads the published assets again and compares their sha256
# `check` and `pack` run in the gate job (contents: read, no token anywhere). `create` and `verify` run in the release job, which has
# no checkout and runs no code of the caller's repository: they only move files and talk to the GitHub API.
# Inputs arrive through env: PACKAGE_DIR TAG_PREFIX NODE_VERSION REF_TYPE REF_NAME (check, pack); OUT_DIR (pack);
# GH_TOKEN GH_REPO ASSETS_DIR TARBALL EXPECTED_SHA256 TAG_PREFIX REF_TYPE REF_NAME (create, verify).
# The token is only ever read by `gh` from its environment: it is never an argument, a file or a line of output.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

cmd="${1:?usage: tarball-release.sh <check|pack|create|verify>}"

errs=()
err() { errs+=("$*"); }
finish() { # prints every problem at once, then fails
  local e
  ((${#errs[@]} == 0)) && return 0
  for e in "${errs[@]}"; do printf '::error::%s\n' "$e" >&2; done
  exit 1
}

STABLE_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
PREFIX_RE='^([a-z][a-z0-9-]*-)?v$'
SHA_RE='^[0-9a-f]{64}$'

package_dir() {
  local d="${PACKAGE_DIR:-.}"
  [[ -n $d ]] || d=.
  printf '%s' "$d"
}

# A tag is a release tag of this workflow only when it is <tag-prefix><X.Y.Z>. Sets TAG_VERSION; returns 1 otherwise.
tag_version() {
  local prefix="${TAG_PREFIX:-}" tag="${REF_NAME:-}"
  [[ $tag == "$prefix"* ]] || return 1
  TAG_VERSION="${tag#"$prefix"}"
  [[ $TAG_VERSION =~ $STABLE_RE ]]
}

case "$cmd" in
  check)
    dir="$(package_dir)"
    prefix="${TAG_PREFIX:-}"
    if [[ $dir != . && ! $dir =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || [[ $dir == *..* ]] || [[ $dir == */ ]]; then
      err "input 'package-dir' must be '.' or a relative path with no '..', no spaces and no trailing '/' (got '$dir')"
    fi
    [[ $prefix =~ $PREFIX_RE ]] || err "input 'tag-prefix' must end in 'v' and use lower case, for example shop-lib-v (got '$prefix')"
    [[ ${NODE_VERSION:-} =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || err "input 'node-version' must be a version such as 22 or 22.11 (got '${NODE_VERSION:-}')"
    # The caller decides when it runs; the only legitimate trigger is the push of a version tag.
    [[ ${REF_TYPE:-} == tag ]] || err "this workflow releases from a version tag only (got ref type '${REF_TYPE:-}', ref '${REF_NAME:-}')"
    finish

    manifest="$dir/package.json"
    [[ -f $manifest ]] || die "package-dir '$dir' has no package.json"
    jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || die "$manifest is not a JSON object"
    name="$(jq -r '.name // empty' "$manifest")"
    version="$(jq -r '.version // empty' "$manifest")"
    [[ -n $name ]] || err "$manifest has no 'name'"
    if [[ ! $version =~ $STABLE_RE ]]; then
      err "package.json version '$version' must be X.Y.Z (a Release is only cut for a stable version; any suffix is refused)"
    else
      expected="${prefix}${version}"
      [[ ${REF_NAME:-} == "$expected" ]] ||
        err "tag '${REF_NAME:-}' does not match the package.json version '$version': the tag for this version is '$expected' (tag-prefix '$prefix' + version)"
    fi
    finish
    log "manifest ok: $name@$version from tag ${REF_NAME:-}"
    ;;

  pack)
    require_env OUT_DIR
    dir="$(package_dir)"
    manifest="$dir/package.json"
    [[ -f $manifest ]] || die "package-dir '$dir' has no package.json"
    mkdir -p "$OUT_DIR"
    [[ -z "$(find "$OUT_DIR" -mindepth 1 -print -quit)" ]] || die "pack: the output directory '$OUT_DIR' is not empty (the tarball must be the only thing in it)"
    version="$(jq -r '.version // empty' "$manifest")"
    name="$(jq -r '.name // empty' "$manifest")"
    # ONE `npm pack`. Lifecycle scripts run here (a package may build in `prepack`): this job holds contents: read and no token, and
    # whatever it produces is reviewed below before the release job ever sees it. Its output goes to a log: the tarball is found on disk.
    packlog="$(mktemp)"
    work="$(mktemp -d)"
    trap 'rm -rf "$packlog" "$work"' EXIT
    out_abs="$(cd "$OUT_DIR" && pwd)"
    (cd "$dir" && npm pack --pack-destination "$out_abs") >"$packlog" 2>&1 || {
      cat "$packlog" >&2
      die "npm pack failed in '$dir'"
    }
    mapfile -t tgz_found < <(find "$out_abs" -maxdepth 1 -type f -name '*.tgz' -printf '%f\n')
    ((${#tgz_found[@]} == 1)) || die "pack: expected exactly one .tgz in '$OUT_DIR', found ${#tgz_found[@]}"
    tgz_name="${tgz_found[0]}"

    # Review of the tarball itself (not of the source tree): findings name the file and the line, never the matched text.
    tar -xzf "$out_abs/$tgz_name" -C "$work" --no-same-owner || die "pack: '$tgz_name' is not a readable tarball"
    [[ -f $work/package/package.json ]] || die "pack: '$tgz_name' has no package/package.json"
    jq -e '.publishConfig == null' "$work/package/package.json" >/dev/null ||
      err "the tarball's package.json sets publishConfig: where a package is published is decided by the workflow, never by the package (remove it)"
    [[ "$(jq -r '.version // empty' "$work/package/package.json")" == "$version" && "$(jq -r '.name // empty' "$work/package/package.json")" == "$name" ]] ||
      err "the tarball's package.json is not $name@$version (the build changed the manifest)"
    mapfile -t files < <(cd "$work" && find package -type f | sort)
    ((${#files[@]} > 1)) || err "the tarball holds no file besides package.json: an empty package is not released"
    acct_re='(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)'
    arn_re='arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:'
    for f in "${files[@]}"; do
      while IFS=: read -r n _; do err "tarball file '${f#package/}' line $n holds an ARN with an account id"; done \
        < <(LC_ALL=C grep -anE "$arn_re" -- "$work/$f" || true)
      while IFS=: read -r n _; do err "tarball file '${f#package/}' line $n holds a 12-digit number that may be a cloud account id"; done \
        < <(LC_ALL=C grep -anE "$acct_re" -- "$work/$f" || true)
    done
    finish

    (cd "$out_abs" && sha256sum "$tgz_name" >"$tgz_name.sha256")
    sha="$(cut -d' ' -f1 "$out_abs/$tgz_name.sha256")"
    [[ $sha =~ $SHA_RE ]] || die "pack: could not compute the sha256 of '$tgz_name'"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
      {
        printf 'tarball=%s\n' "$tgz_name"
        printf 'sha256=%s\n' "$sha"
        printf 'dir=%s\n' "$out_abs"
      } >>"$GITHUB_OUTPUT"
    fi
    log "packed and reviewed: $tgz_name (${#files[@]} files, sha256 $sha)"
    ;;

  create | verify)
    require_env GH_TOKEN GH_REPO ASSETS_DIR TARBALL EXPECTED_SHA256 TAG_PREFIX REF_NAME
    mask "$GH_TOKEN" # BEFORE the first use of the value
    tag="$REF_NAME"
    # This job holds contents: write, so it re-checks what it is about to release instead of trusting the previous job.
    [[ ${REF_TYPE:-} == tag ]] || die "this workflow releases from a version tag only (got ref type '${REF_TYPE:-}')"
    [[ $TAG_PREFIX =~ $PREFIX_RE ]] || die "input 'tag-prefix' must end in 'v' and use lower case (got '$TAG_PREFIX')"
    tag_version || die "tag '$tag' is not '${TAG_PREFIX}X.Y.Z': nothing was released"
    [[ $TARBALL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.tgz$ ]] || die "tarball name '$TARBALL' is not a plain .tgz file name"
    [[ $TARBALL == *"-${TAG_VERSION}.tgz" ]] || die "tarball '$TARBALL' is not the tarball of version $TAG_VERSION (tag '$tag')"
    [[ $EXPECTED_SHA256 =~ $SHA_RE ]] || die "the expected sha256 is not a 64-hex digest"
    tgz="$ASSETS_DIR/$TARBALL"
    shafile="$tgz.sha256"
    [[ -f $tgz && -f $shafile ]] || die "the artifact holds no '$TARBALL' with its .sha256 (assets dir '$ASSETS_DIR')"

    if [[ $cmd == create ]]; then
      # The digest of the artifact must be the one the gate computed (it travelled apart, as a job output), and the .sha256 must agree.
      got="$(sha256sum "$tgz" | cut -d' ' -f1)"
      [[ $got == "$EXPECTED_SHA256" ]] || die "the downloaded tarball's sha256 ($got) is not the one the gate computed ($EXPECTED_SHA256): it changed between the jobs; nothing was released"
      [[ "$(cut -d' ' -f1 "$shafile")" == "$EXPECTED_SHA256" ]] || die "the .sha256 file does not carry the digest the gate computed: nothing was released"
      # A published Release is never rewritten. "Not found" is told apart from every other failure (permissions, outage): only
      # a clean "release not found" lets the creation go on.
      errfile="$(mktemp)"
      trap 'rm -f "$errfile"' EXIT
      if gh release view "$tag" >/dev/null 2>"$errfile"; then
        die "the Release '$tag' already exists: a published Release is never rewritten (bump the version and tag again)"
      fi
      grep -qi 'release not found' "$errfile" || {
        cat "$errfile" >&2
        die "could not tell whether the Release '$tag' exists (neither found nor 'release not found'): nothing was released"
      }
      gh release create "$tag" "$tgz" "$shafile" --verify-tag --title "$tag" --notes "Package tarball and its sha256. Verify with: sha256sum --check ${TARBALL}.sha256" ||
        die "gh release create failed for '$tag'"
      log "created the Release '$tag' with $TARBALL and its .sha256"
    else
      verify_dir="$(mktemp -d)"
      trap 'rm -rf "$verify_dir"' EXIT
      gh release download "$tag" --dir "$verify_dir" --pattern "$TARBALL" --pattern "$TARBALL.sha256" ||
        die "could not download the assets of the Release '$tag' to verify them"
      [[ -f $verify_dir/$TARBALL && -f $verify_dir/$TARBALL.sha256 ]] || die "the Release '$tag' does not carry both '$TARBALL' and its .sha256"
      got="$(sha256sum "$verify_dir/$TARBALL" | cut -d' ' -f1)"
      [[ $got == "$EXPECTED_SHA256" ]] ||
        die "the published '$TARBALL' has sha256 $got, expected $EXPECTED_SHA256: the Release does not hold the reviewed bytes (do not use it; release a new version)"
      [[ "$(cut -d' ' -f1 "$verify_dir/$TARBALL.sha256")" == "$EXPECTED_SHA256" ]] ||
        die "the published .sha256 does not carry the digest of the reviewed tarball ($EXPECTED_SHA256)"
      summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
      {
        echo "### Package released"
        echo ""
        echo "| | |"
        echo "|---|---|"
        echo "| Tag | \`$tag\` |"
        echo "| Tarball | \`$TARBALL\` |"
        echo "| sha256 | \`$EXPECTED_SHA256\` |"
      } >>"$summary"
      log "verified: the Release '$tag' holds $TARBALL with sha256 $EXPECTED_SHA256"
    fi
    ;;

  *) die "package-release: unknown subcommand '$cmd'" ;;
esac
