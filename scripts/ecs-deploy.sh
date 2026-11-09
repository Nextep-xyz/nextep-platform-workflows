#!/usr/bin/env bash
# P-CI-13: update-service --force-new-deployment (the only mode of P1; no task definition is registered here).
# Env: AWS_REGION ECS_CLUSTER_PARAM ECS_SERVICE_PARAM (resolved SSM parameter names)
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env AWS_REGION ECS_CLUSTER_PARAM ECS_SERVICE_PARAM

cluster="$(aws ssm get-parameter --region "$AWS_REGION" --name "$ECS_CLUSTER_PARAM" --query 'Parameter.Value' --output text)" ||
  die "could not read the cluster name from '$ECS_CLUSTER_PARAM'"
service="$(aws ssm get-parameter --region "$AWS_REGION" --name "$ECS_SERVICE_PARAM" --query 'Parameter.Value' --output text)" ||
  die "could not read the service name from '$ECS_SERVICE_PARAM'"
aws ecs update-service --region "$AWS_REGION" --cluster "$cluster" --service "$service" --force-new-deployment \
  --query 'service.serviceName' --output text >/dev/null || die "update-service failed for $cluster/$service"
log "forced a new deployment of $service on $cluster"
