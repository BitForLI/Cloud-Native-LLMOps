#!/usr/bin/env bash
set -Eeuo pipefail

required=(AWS_ACCOUNT_ID AWS_REGION DEV_API_ECR_REPOSITORY DEV_WORKER_ECR_REPOSITORY STAGING_API_ECR_REPOSITORY STAGING_WORKER_ECR_REPOSITORY ECS_CLUSTER API_ECS_SERVICE WORKER_ECS_SERVICE API_URL API_AUTH_SECRET_ID IMAGE_TAG)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "Missing required variable: ${name}" >&2; exit 1; }
done
[[ "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] || { echo "IMAGE_TAG must be a 40-character commit SHA" >&2; exit 1; }
[[ "$API_URL" =~ ^https://[^/]+/?$ ]] || { echo "Staging API_URL must be an HTTPS origin" >&2; exit 1; }

registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
builder_identity="https://github.com/BitForLI/Cloud-Native-LLMOps/.github/workflows/deploy-dev.yml@refs/heads/master"
staging_identity="https://github.com/BitForLI/Cloud-Native-LLMOps/.github/workflows/promote-staging.yml@refs/heads/master"
oidc_issuer="https://token.actions.githubusercontent.com"

API_AUTH_TOKEN=$(aws secretsmanager get-secret-value --secret-id "$API_AUTH_SECRET_ID" --query SecretString --output text)
[[ "$API_AUTH_TOKEN" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || { echo "Staging API authentication secret must contain 32-128 URL-safe characters" >&2; exit 1; }
echo "::add-mask::${API_AUTH_TOKEN}"
export EVAL_API_TOKEN="$API_AUTH_TOKEN"
auth_header=(--header "X-API-Key: ${API_AUTH_TOKEN}")

scan_gate() {
  local repository="$1"
  aws ecr wait image-scan-complete --repository-name "$repository" --image-id imageTag="$IMAGE_TAG"
  local findings critical high
  findings=$(aws ecr describe-image-scan-findings --repository-name "$repository" --image-id imageTag="$IMAGE_TAG" --output json)
  critical=$(jq -r '.imageScanFindings.findingSeverityCounts.CRITICAL // 0' <<<"$findings")
  high=$(jq -r '.imageScanFindings.findingSeverityCounts.HIGH // 0' <<<"$findings")
  echo "${repository}: CRITICAL=${critical}, HIGH=${high}"
  [[ "$critical" -eq 0 && "$high" -eq 0 ]] || { echo "Vulnerability gate failed for ${repository}" >&2; return 1; }
}

verify_builder_supply_chain() {
  local image_ref="$1"
  cosign verify \
    --certificate-identity "$builder_identity" \
    --certificate-oidc-issuer "$oidc_issuer" \
    --annotations "git_sha=${IMAGE_TAG}" "$image_ref" >/dev/null
  cosign verify-attestation \
    --certificate-identity "$builder_identity" \
    --certificate-oidc-issuer "$oidc_issuer" \
    --type spdxjson "$image_ref" >/dev/null
}

sign_staging_image() {
  local image_ref="$1"
  if ! cosign verify \
    --certificate-identity "$staging_identity" \
    --certificate-oidc-issuer "$oidc_issuer" \
    --annotations "git_sha=${IMAGE_TAG}" "$image_ref" >/dev/null 2>&1; then
    cosign sign --yes --annotations "git_sha=${IMAGE_TAG}" "$image_ref"
  fi
  cosign verify \
    --certificate-identity "$staging_identity" \
    --certificate-oidc-issuer "$oidc_issuer" \
    --annotations "git_sha=${IMAGE_TAG}" "$image_ref" >/dev/null
}

promote_image() {
  local source_repository="$1" destination_repository="$2"
  scan_gate "$source_repository"

  local manifest source_digest destination_digest
  manifest=$(aws ecr batch-get-image --repository-name "$source_repository" --image-ids imageTag="$IMAGE_TAG" --query 'images[0].imageManifest' --output text)
  source_digest=$(aws ecr describe-images --repository-name "$source_repository" --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  [[ -n "$manifest" && "$manifest" != "None" && "$source_digest" == sha256:* ]] || { echo "Source image is missing: ${source_repository}:${IMAGE_TAG}" >&2; return 1; }
  verify_builder_supply_chain "${registry}/${source_repository}@${source_digest}"

  if aws ecr describe-images --repository-name "$destination_repository" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Destination tag already exists; verifying immutable digest"
  else
    aws ecr put-image --repository-name "$destination_repository" --image-tag "$IMAGE_TAG" --image-manifest "$manifest" >/dev/null
  fi
  destination_digest=$(aws ecr describe-images --repository-name "$destination_repository" --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  [[ "$destination_digest" == "$source_digest" ]] || { echo "Promotion changed the image digest" >&2; return 1; }
  scan_gate "$destination_repository"
  sign_staging_image "${registry}/${destination_repository}@${destination_digest}"
  echo "Promoted ${source_repository}@${source_digest} to ${destination_repository}:${IMAGE_TAG}"
}

promote_image "$DEV_API_ECR_REPOSITORY" "$STAGING_API_ECR_REPOSITORY"
promote_image "$DEV_WORKER_ECR_REPOSITORY" "$STAGING_WORKER_ECR_REPOSITORY"

api_digest=$(aws ecr describe-images --repository-name "$STAGING_API_ECR_REPOSITORY" --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
worker_digest=$(aws ecr describe-images --repository-name "$STAGING_WORKER_ECR_REPOSITORY" --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
api_image="${registry}/${STAGING_API_ECR_REPOSITORY}@${api_digest}"
worker_image="${registry}/${STAGING_WORKER_ECR_REPOSITORY}@${worker_digest}"
[[ "$api_digest" == sha256:* && "$worker_digest" == sha256:* ]]
previous_api_task=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$API_ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
previous_worker_task=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$WORKER_ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
deployment_started=false

rollback() {
  local exit_code=$?
  trap - ERR
  if [[ "$deployment_started" == true ]]; then
    echo "Staging verification failed; restoring both previous task definitions" >&2
    aws ecs update-service --cluster "$ECS_CLUSTER" --service "$API_ECS_SERVICE" --task-definition "$previous_api_task" >/dev/null || true
    aws ecs update-service --cluster "$ECS_CLUSTER" --service "$WORKER_ECS_SERVICE" --task-definition "$previous_worker_task" >/dev/null || true
    aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$API_ECS_SERVICE" "$WORKER_ECS_SERVICE" || true
  fi
  exit "$exit_code"
}
trap rollback ERR

aws ecs describe-task-definition --task-definition "$previous_api_task" --query taskDefinition --output json | jq --arg image "$api_image" 'del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy,.deregisteredAt) | (.containerDefinitions[] | select(.name == "api") | .image) = $image' > api-task-definition.json
aws ecs describe-task-definition --task-definition "$previous_worker_task" --query taskDefinition --output json | jq --arg image "$worker_image" 'del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy,.deregisteredAt) | (.containerDefinitions[] | select(.name == "worker") | .image) = $image' > worker-task-definition.json
new_api_task=$(aws ecs register-task-definition --cli-input-json file://api-task-definition.json --query taskDefinition.taskDefinitionArn --output text)
new_worker_task=$(aws ecs register-task-definition --cli-input-json file://worker-task-definition.json --query taskDefinition.taskDefinitionArn --output text)

deployment_started=true
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$WORKER_ECS_SERVICE" --task-definition "$new_worker_task" >/dev/null
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$API_ECS_SERVICE" --task-definition "$new_api_task" >/dev/null
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$API_ECS_SERVICE" "$WORKER_ECS_SERVICE"
active_api_task=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$API_ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
active_worker_task=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$WORKER_ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
[[ "$active_api_task" == "$new_api_task" && "$active_worker_task" == "$new_worker_task" ]] || { echo "ECS circuit breaker restored an older staging revision" >&2; false; }

api_origin=${API_URL%/}
health=$(curl --fail --silent --show-error "${api_origin}/health")
[[ "$(jq -r '.status' <<<"$health")" == "ok" && "$(jq -r '.environment' <<<"$health")" == "staging" ]]
curl --fail --silent --show-error "${api_origin}/ready" | jq -e '.status == "ready"' >/dev/null
unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/json' -d '{"prompt":"must be rejected"}' "${api_origin}/v1/generate")
[[ "$unauthenticated_status" == "401" ]] || { echo "Staging inference endpoint accepted an unauthenticated request" >&2; false; }
curl --fail --silent --show-error "${auth_header[@]}" -H 'Content-Type: application/json' -d '{"prompt":"staging synchronous integration test"}' "${api_origin}/v1/generate" | jq -e '.output | type == "string" and length > 0' >/dev/null
python -m evals.run_remote_eval --base-url "$api_origin"

job_id=$(curl --fail --silent --show-error "${auth_header[@]}" -H 'Content-Type: application/json' -d '{"prompt":"staging worker integration test"}' "${api_origin}/v1/jobs" | jq -er '.job_id')
job_succeeded=false
for attempt in {1..36}; do
  job=$(curl --fail --silent --show-error "${auth_header[@]}" "${api_origin}/v1/jobs/${job_id}")
  case "$(jq -r '.status' <<<"$job")" in
    succeeded) jq -e '.output | type == "string" and length > 0' <<<"$job" >/dev/null; job_succeeded=true; break ;;
    failed) echo "Asynchronous staging inference failed" >&2; false ;;
  esac
  sleep 5
done
[[ "$job_succeeded" == true ]] || { echo "Asynchronous staging inference timed out" >&2; false; }

trap - ERR
echo "Staging deployed and verified at ${IMAGE_TAG}"
