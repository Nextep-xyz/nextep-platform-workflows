#!/usr/bin/env bash
# One tunnel session per job (P1-D7): [secret] -> tunnel up -> wait -> commands -> teardown (always).
#   cicd:               verify; if it fails (pending): pre -> migrate -> verify (must pass); then post (seed).
#   environment-deploy: pre -> migrate -> verify (MUST pass, else the job fails red) -> post (seed).
# DB_ACCESS=iam-direct (P2-D2): no tunnel, no secret, no DATABASE_URL. The commands get DB_ENDPOINT and the OIDC
# session of the job (AWS_* in the environment) and sign their own IAM token.
# The DATABASE_URL exists ONLY in the environment of the commands it runs, never in the runner env file or in a step output.
#
# Env (set by the migrate composite):
#   MODE AWS_REGION BASTION_ID DB_ENDPOINT DB_PORT DB_SECRET_ID DB_NAME DB_SCHEMA DB_SSL_MODE DB_URL_TEMPLATE CA_BUNDLE
#   DB_ACCESS (ssm-tunnel | iam-direct, default ssm-tunnel); with iam-direct only MODE AWS_REGION DB_ENDPOINT and the
#   three commands are required (DB_ENDPOINT_PARAM may replace DB_ENDPOINT: it is read from SSM)
#   MIGRATION_PRE_COMMAND MIGRATION_COMMAND MIGRATION_VERIFY_COMMAND POST_MIGRATE_COMMAND MIGRATION_TIMEOUT_MINUTES
#   PROJECT APP_ENV APP_STAGE STACK_SUFFIX (contract variables, inherited by the commands)
#   TUNNEL_TIMEOUT / TUNNEL_INTERVAL (defaults 60 / 2)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=fetch-db-secret.sh
source "$here/fetch-db-secret.sh"

DB_ACCESS="${DB_ACCESS:-ssm-tunnel}"
case "$DB_ACCESS" in ssm-tunnel | iam-direct) ;; *) die "run-migration: db-access must be ssm-tunnel or iam-direct (got '$DB_ACCESS')" ;; esac
if [[ $DB_ACCESS == iam-direct ]]; then
  if [[ -z ${DB_ENDPOINT:-} && -n ${DB_ENDPOINT_PARAM:-} ]]; then
    DB_ENDPOINT="$(aws ssm get-parameter --region "${AWS_REGION:-}" --name "$DB_ENDPOINT_PARAM" --query Parameter.Value --output text)" ||
      die "run-migration: could not read the database endpoint from SSM parameter '$DB_ENDPOINT_PARAM'"
  fi
  require_env MODE AWS_REGION DB_ENDPOINT MIGRATION_COMMAND MIGRATION_VERIFY_COMMAND
else
  require_env MODE AWS_REGION BASTION_ID DB_ENDPOINT DB_PORT DB_SECRET_ID DB_NAME DB_SSL_MODE DB_URL_TEMPLATE MIGRATION_COMMAND MIGRATION_VERIFY_COMMAND
  case "$DB_SSL_MODE" in verify-full | require) ;; *) die "run-migration: db-ssl-mode must be verify-full or require (got '$DB_SSL_MODE')" ;; esac
  if [[ $DB_SSL_MODE == verify-full && -z ${CA_BUNDLE:-} ]]; then
    die "run-migration: db-ssl-mode=verify-full needs CA_BUNDLE (the pinned RDS CA bundle)"
  fi
fi
[[ $MODE == cicd || $MODE == environment-deploy ]] || die "run-migration: MODE must be cicd or environment-deploy (got '$MODE')"
timeout_min="${MIGRATION_TIMEOUT_MINUTES:-20}"
tunnel_dir="${TUNNEL_DIR:-${RUNNER_TEMP:-/tmp}/ssm-tunnel}"

url=""
ca_for_cmd=""
iam_endpoint="${DB_ENDPOINT:-}"
if [[ $DB_ACCESS == ssm-tunnel ]]; then
  teardown() { "$here/ssm-tunnel-down.sh" || true; }
  trap teardown EXIT

  # 1. credentials: masked first, kept in non-exported variables
  fetch_db_secret "$DB_SECRET_ID"
  url="$(TPL_USER="$DB_USER" TPL_PASSWORD="$DB_PASSWORD" TPL_HOST="$DB_ENDPOINT" TPL_PORT="$DB_PORT" TPL_DB="$DB_NAME" \
    TPL_SCHEMA="${DB_SCHEMA:-}" TPL_SSLMODE="$DB_SSL_MODE" TPL_PROJECT="${PROJECT:-}" TPL_STAGE="${APP_STAGE:-}" \
    TPL_ENV="${APP_ENV:-}" TPL_REGION="$AWS_REGION" \
    "$here/resolve-template.sh" --db-url db-url-template "$DB_URL_TEMPLATE")"
  mask "$url"

  # 2. tunnel
  "$here/ssm-tunnel-up.sh"
  pid="$(cat "$tunnel_dir/ssm-tunnel.pid")"
  "$here/wait-for-port.sh" --port "$DB_PORT" --pid "$pid" --log "$tunnel_dir/ssm-tunnel.log" \
    --timeout "${TUNNEL_TIMEOUT:-60}" --interval "${TUNNEL_INTERVAL:-2}"

  ca_for_cmd="${CA_BUNDLE:-}"
fi

# 3. commands. The subshell scopes DATABASE_URL and drops this script's own control variables.
access_mode="$DB_ACCESS" # DB_ACCESS itself is unset inside the command subshell
run_db() { # run_db <stage-name> <command>
  local stage=$1 cmd=$2 rc=0
  log "::group::${stage}"
  (
    unset MODE BASTION_ID DB_ENDPOINT DB_ENDPOINT_PARAM DB_ACCESS DB_SECRET_ID DB_URL_TEMPLATE DB_USER DB_PASSWORD DB_NAME DB_SCHEMA DB_PORT DB_SSL_MODE \
      CA_BUNDLE TUNNEL_TIMEOUT TUNNEL_INTERVAL \
      MIGRATION_PRE_COMMAND MIGRATION_COMMAND MIGRATION_VERIFY_COMMAND POST_MIGRATE_COMMAND MIGRATION_TIMEOUT_MINUTES
    if [[ $access_mode == iam-direct ]]; then
      export DB_ENDPOINT="$iam_endpoint"
    else
      export DATABASE_URL="$url"
    fi
    if [[ -n $ca_for_cmd ]]; then
      export PGSSLROOTCERT="$ca_for_cmd" NODE_EXTRA_CA_CERTS="$ca_for_cmd"
    fi
    exec timeout "${timeout_min}m" bash -c "$cmd"
  ) || rc=$?
  log "::endgroup::"
  if ((rc == 124)); then die "stage '$stage' timed out after ${timeout_min} minutes"; fi
  return "$rc"
}

must() { # must <stage> <command>: failure of the stage fails the job
  local rc=0
  run_db "$1" "$2" || rc=$?
  ((rc == 0)) || die "stage '$1' failed (exit $rc)"
}

pending=1
if [[ $MODE == cicd ]]; then
  if run_db "migration status" "$MIGRATION_VERIFY_COMMAND"; then
    log "database aligned: no pending migrations, migration skipped"
    pending=0
  fi
fi

if ((pending)); then
  [[ -z ${MIGRATION_PRE_COMMAND:-} ]] || must "migration pre-command" "$MIGRATION_PRE_COMMAND"
  must "migration" "$MIGRATION_COMMAND"
  run_db "migration verify" "$MIGRATION_VERIFY_COMMAND" || die "the database is NOT aligned after migrating (verify command failed)"
fi

[[ -z ${POST_MIGRATE_COMMAND:-} ]] || must "post-migrate (seed)" "$POST_MIGRATE_COMMAND"
log "database stage finished (mode=$MODE, migrated=$pending)"
