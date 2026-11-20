#!/usr/bin/env bash
# Builds with plain `docker build` (equivalent to the reference build, see the spec Q6) and pushes the immutable
# tag <commit sha>. `latest` is pushed ONLY in dev (where the task definition may still point to it).
# Idempotent per commit: if <commit sha> already exists in the repository (re-run, or `base` then `full` on the same commit)
# nothing is built or pushed (the repository's tags are immutable, so a second push of the same tag is refused by ECR).
# Env: AWS_REGION REGISTRY ECR_REPOSITORY IMAGE_TAG ENVIRONMENT DOCKERFILE BUILD_CONTEXT [BUILD_TARGET] [BUILD_PLATFORM]
# BUILD_PLATFORM (optional, e.g. linux/amd64) adds `--platform`; unset, the docker command is exactly what it always was.
# Output: image (registry/repository:tag)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env AWS_REGION REGISTRY ECR_REPOSITORY IMAGE_TAG ENVIRONMENT DOCKERFILE BUILD_CONTEXT
[[ $IMAGE_TAG =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "invalid image tag '$IMAGE_TAG'"

image="$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"

# Only ImageNotFoundException means "not pushed yet"; any other failure (credentials, network) fails hard.
if err="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$ECR_REPOSITORY"   --image-ids "imageTag=$IMAGE_TAG" --output text 2>&1 >/dev/null)"; then
  log "image $ECR_REPOSITORY:$IMAGE_TAG already exists in ECR: build and push skipped (same commit, immutable tag)"
  printf 'image=%s
' "$image" >>"${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
fi
[[ $err == *ImageNotFoundException* ]] || die "cannot check whether '$ECR_REPOSITORY:$IMAGE_TAG' exists in ECR: $err"

args=(build --file "$DOCKERFILE" --tag "$image")
[[ -z ${BUILD_TARGET:-} ]] || args+=(--target "$BUILD_TARGET")
[[ -z ${BUILD_PLATFORM:-} ]] || args+=(--platform "$BUILD_PLATFORM")
if [[ $ENVIRONMENT == dev ]]; then args+=(--tag "$REGISTRY/$ECR_REPOSITORY:latest"); fi
args+=("$BUILD_CONTEXT")

docker "${args[@]}"
docker push "$image"
if [[ $ENVIRONMENT == dev ]]; then docker push "$REGISTRY/$ECR_REPOSITORY:latest"; fi
printf 'image=%s\n' "$image" >>"${GITHUB_OUTPUT:-/dev/stdout}"
