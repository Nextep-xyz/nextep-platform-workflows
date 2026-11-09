#!/usr/bin/env bash
# The image tag must exist in ECR (rollback by image-tag never rebuilds). Env: AWS_REGION ECR_REPOSITORY IMAGE_TAG
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env AWS_REGION ECR_REPOSITORY IMAGE_TAG

if ! aws ecr describe-images --region "$AWS_REGION" --repository-name "$ECR_REPOSITORY" \
  --image-ids "imageTag=$IMAGE_TAG" --query 'imageDetails[0].imageTags' --output text >/dev/null 2>&1; then
  die "image '$ECR_REPOSITORY:$IMAGE_TAG' does not exist in ECR: the rollback is aborted (nothing was changed)"
fi
log "image $ECR_REPOSITORY:$IMAGE_TAG exists"
