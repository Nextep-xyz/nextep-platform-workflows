#!/usr/bin/env bash
# Prints `account-id=<12 digits>` (GITHUB_OUTPUT format) for the credentials of the current session (P2-D9 / GH5).
# The account id is derived from the assumed role, never taken from an input or a literal. Needs: aws.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
account="$(aws sts get-caller-identity --query Account --output text)" || die "could not read the caller identity (sts get-caller-identity)"
[[ $account =~ ^[0-9]{12}$ ]] || die "sts get-caller-identity did not return a 12-digit account id"
printf 'account-id=%s\n' "$account"
