# shellcheck shell=bash
# Strict semantic versions for the package catalog (contracts/package-profiles.yml, section `packages:`): exactly X.Y.Z, plain numbers.
# A prerelease, a build suffix, a leading zero, a URL or anything else is NOT valid: the policy treats what it cannot compare as a finding
# (fail-closed), it never guesses an order.

SEMVER_RE='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'

# semver_valid <version>: success when it is exactly X.Y.Z
semver_valid() { [[ ${1-} =~ $SEMVER_RE ]]; }

# semver_cmp <a> <b>: prints -1, 0 or 1 (a < b, a = b, a > b). Both must be valid; otherwise returns 2 and prints nothing.
semver_cmp() {
  semver_valid "${1-}" && semver_valid "${2-}" || return 2
  local -a a b
  local i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if ((a[i] < b[i])); then
      printf -- '-1'
      return 0
    elif ((a[i] > b[i])); then
      printf '1'
      return 0
    fi
  done
  printf '0'
}

# semver_lt <a> <b>: success when a < b (both valid)
semver_lt() {
  local c
  c="$(semver_cmp "$1" "$2")" || return 2
  [[ $c == -1 ]]
}
