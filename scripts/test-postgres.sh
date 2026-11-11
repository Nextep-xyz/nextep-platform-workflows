#!/usr/bin/env bash
# Ephemeral Postgres for integration tests (P-CI-03). The password is random and masked; the URL goes to the step
# OUTPUT (database-url) so only the test step that asks for it sees it. Never the runner env file.
# Env: TEST_PG_PORT (default 5432), TEST_PG_IMAGE (default postgres:16-alpine; empty means the default),
#      TEST_PG_TIMEOUT (default 60). `test-postgres.sh --stop` removes the container (the composite runs it with always()).
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

name=lego-test-postgres
if [[ ${1:-} == --stop ]]; then # always-run cleanup step: removes the container even when the tests failed
  docker rm --force --volumes "$name" >/dev/null 2>&1 || true
  log "ephemeral Postgres removed"
  exit 0
fi

port="${TEST_PG_PORT:-5432}"
image="${TEST_PG_IMAGE:-}"
[[ -n $image ]] || image=postgres:16-alpine
password="$(openssl rand -hex 16)"
mask "$password"

docker run --detach --name "$name" -e POSTGRES_USER=test -e POSTGRES_PASSWORD="$password" -e POSTGRES_DB=test \
  -p "127.0.0.1:${port}:5432" "$image" >/dev/null

start=$SECONDS
until docker exec "$name" pg_isready -U test -d test >/dev/null 2>&1; do
  if ((SECONDS - start >= ${TEST_PG_TIMEOUT:-60})); then
    docker logs "$name" >&2 || true
    die "ephemeral Postgres did not become ready within ${TEST_PG_TIMEOUT:-60}s"
  fi
  sleep 1
done

url="postgresql://test:${password}@127.0.0.1:${port}/test"
mask "$url"
printf 'database-url=%s\n' "$url" >>"${GITHUB_OUTPUT:-/dev/stdout}"
log "ephemeral Postgres ready on 127.0.0.1:${port}"
