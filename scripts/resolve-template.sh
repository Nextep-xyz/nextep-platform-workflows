#!/usr/bin/env bash
# Resolves the {placeholders} of a template input.
#   resolve-template.sh [--db-url] [--check] <input-name> <template>
# Values come from TPL_PROJECT, TPL_STAGE, TPL_ENV, TPL_REGION (+ TPL_USER, TPL_PASSWORD, TPL_HOST, TPL_PORT,
# TPL_DB, TPL_SCHEMA, TPL_SSLMODE with --db-url). {password} is URL-encoded.
# An unknown placeholder fails NAMING the placeholder and the input. --check validates without values.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

db_url=0
check=0
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --db-url) db_url=1 ;;
    --check) check=1 ;;
    *) die "resolve-template: unknown option $1" ;;
  esac
  shift
done
name="${1:?usage: resolve-template.sh [--db-url] [--check] <input-name> <template>}"
template="${2-}"

base_keys="project stage env region"
db_keys="user password host port db schema sslmode"
allowed="$base_keys"
((db_url)) && allowed="$base_keys $db_keys"

out=''
rest="$template"
while [[ $rest =~ ^([^\{]*)\{([^\{\}]*)\}(.*)$ ]]; do
  out+="${BASH_REMATCH[1]}"
  key="${BASH_REMATCH[2]}"
  rest="${BASH_REMATCH[3]}"
  if [[ " $allowed " != *" $key "* ]]; then
    die "input '$name': unknown placeholder '{$key}' (allowed: $allowed)"
  fi
  if ((check)); then
    continue
  fi
  var="TPL_${key^^}"
  value="${!var:-}"
  if [[ -z $value ]]; then
    die "input '$name': placeholder '{$key}' has no value (is the matching input empty?)"
  fi
  [[ $key == password ]] && value="$(urlencode "$value")"
  out+="$value"
done
if [[ $rest == *'{'* || $rest == *'}'* ]]; then
  die "input '$name': unbalanced braces in template"
fi
out+="$rest"
((check)) || printf '%s\n' "$out"
