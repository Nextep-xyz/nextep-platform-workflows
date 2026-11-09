#!/usr/bin/env bash
# Library: SOURCE this file, then call `fetch_db_secret <secret-id>`.
# Reads the secret (keys: username, password), MASKS the raw and the URL-encoded password and the user
# BEFORE any other use, and leaves them in the shell variables DB_USER and DB_PASSWORD. They are never exported,
# never written to the runner env file, never printed. Needs: AWS_REGION, aws, jq.
# shellcheck shell=bash
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

fetch_db_secret() {
  local secret_id=$1 raw user password
  raw="$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$secret_id" --query SecretString --output text)" ||
    die "could not read the database secret '$secret_id'"
  user="$(jq -r '.username // empty' <<<"$raw")" || die "the secret '$secret_id' is not valid JSON"
  password="$(jq -r '.password // empty' <<<"$raw")"
  raw=""
  [[ -n $user && -n $password ]] || die "the secret '$secret_id' must contain the keys 'username' and 'password'"
  mask "$user"
  mask "$password"
  mask "$(urlencode "$password")"
  # shellcheck disable=SC2034 # consumed by the script that sources this library
  DB_USER=$user
  # shellcheck disable=SC2034
  DB_PASSWORD=$password
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  die "fetch-db-secret.sh is a library: source it and call fetch_db_secret <secret-id>"
fi
