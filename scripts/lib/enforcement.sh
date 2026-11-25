# shellcheck shell=bash
# The ONE place that turns an environment into the mode of the packages policy (docs/runbook.md section 12).
#   enforcement_mode <environment>  ->  enforce | warn
#     dev  -> enforce    stg -> enforce    prod -> warn
#     anything else, an empty value or a typo ('Prod', 'production', 'prod ') -> enforce: fail-closed, what is unknown never relaxes the policy.
# Every consumer (run-command.sh, the policy, the guardrails step, the evidence block) calls this function; none of them compares an
# environment name to decide a mode. The gate EN-SINGLE walks the scripts and composites and fails when one does.

enforcement_mode() {
  case "${1-}" in
    dev | stg) printf 'enforce' ;;
    prod) printf 'warn' ;;
    *) printf 'enforce' ;;
  esac
}
