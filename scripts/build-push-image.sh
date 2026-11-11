#!/usr/bin/env bash
# Builds with plain `docker build` (equivalent to the reference build, see the spec Q6) and pushes the immutable
# tag <commit sha>. `latest` is pushed ONLY in dev (where the task definition may still point to it).
# Env: REGISTRY ECR_REPOSITORY IMAGE_TAG ENVIRONMENT DOCKERFILE DOCKER_CONTEXT [DOCKER_TARGET]
# Output: image (registry/repository:tag)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env REGISTRY ECR_REPOSITORY IMAGE_TAG ENVIRONMENT DOCKERFILE DOCKER_CONTEXT
[[ $IMAGE_TAG =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag '$IMAGE_TAG'"

image="$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
args=(build --file "$DOCKERFILE" --tag "$image")
[[ -z ${DOCKER_TARGET:-} ]] || args+=(--target "$DOCKER_TARGET")
if [[ $ENVIRONMENT == dev ]]; then args+=(--tag "$REGISTRY/$ECR_REPOSITORY:latest"); fi
args+=("$DOCKER_CONTEXT")

docker "${args[@]}"
docker push "$image"
if [[ $ENVIRONMENT == dev ]]; then docker push "$REGISTRY/$ECR_REPOSITORY:latest"; fi
printf 'image=%s\n' "$image" >>"${GITHUB_OUTPUT:-/dev/stdout}"
