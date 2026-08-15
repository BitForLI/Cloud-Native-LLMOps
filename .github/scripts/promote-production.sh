#!/usr/bin/env bash
set -Eeuo pipefail

required=(AWS_ACCOUNT_ID AWS_REGION STAGING_API_ECR_REPOSITORY STAGING_WORKER_ECR_REPOSITORY PRODUCTION_API_ECR_REPOSITORY PRODUCTION_WORKER_ECR_REPOSITORY ECS_CLUSTER API_ECS_SERVICE WORKER_ECS_SERVICE API_URL API_AUTH_SECRET_ID CODEDEPLOY_APPLICATION CODEDEPLOY_DEPLOYMENT_GROUP IMAGE_TAG)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "Missing required variable: ${name}" >&2; exit 1; }
done
[[ "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] || { echo "IMAGE_TAG must be a 40-character commit SHA" >&2; exit 1; }
[[ "$API_URL" =~ ^https://[^/]+/?$ ]] || { echo "Production API_URL must be an HTTPS origin" >&2; exit 1; }

API_AUTH_TOKEN=$(aws secretsmanager get-secret-value --secret-id "$API_AUTH_SECRET_ID" --query SecretString --output text)
[[ "$API_AUTH_TOKEN" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || { echo "Production API authentication secret must contain 32-128 URL-safe characters" >&2; exit 1; }
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
  [[ "$critical" -eq 0 && "$high" -eq 0 ]] || { echo "Vulnerability gate failed for ${repository}: CRITICAL=${critical}, HIGH=${high}" >&2; return 1; }
}

promote_image() {
  local source_repository="$1" destination_repository="$2"
  scan_gate "$source_repository"
  local manifest source_digest destination_digest
  manifest=$(aws ecr batch-get-image --repository-name "$source_repository" --image-ids imageTag="$IMAGE_TAG" --query 'images[0].imageManifest' --output text)
  source_digest=$(aws ecr describe-images --repository-name "$source_repository" --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  [[ -n "$manifest" && "$manifest" != "None" && "$source_digest" == sha256:* ]] || { echo "Source image is missing: ${source_repository}:${IMAGE_TAG}" >&2; return 1; }
  if ! aws ecr describe-images --repository-name "$destination_repository" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
    aws ecr put-image --repository-name "$destination_repository" --image-tag "$IMAGE_TAG" --image-manifest "$manifest" >/dev/null
  fi
  destination_digest=$(aws ecr describe-images --repository-name "$destination_repository" --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
  [[ "$destination_digest" == "$source_digest" ]] || { echo "Production promotion changed the image digest" >&2; return 1; }
  scan_gate "$destination_repository"
  echo "Promoted ${source_repository}@${source_digest} to ${destination_repository}:${IMAGE_TAG}"
}

create_api_deployment() {
  local task_definition="$1" description="$2" appspec revision
  appspec=$(jq -nc --arg task "$task_definition" '{version:1,Resources:[{TargetService:{Type:"AWS::ECS::Service",Properties:{TaskDefinition:$task,LoadBalancerInfo:{ContainerName:"api",ContainerPort:8000},PlatformVersion:"1.4.0"}}}]}')
  revision=$(jq -nc --arg content "$appspec" '{revisionType:"AppSpecContent",appSpecContent:{content:$content}}')
  aws deploy create-deployment \
    --application-name "$CODEDEPLOY_APPLICATION" \
    --deployment-group-name "$CODEDEPLOY_DEPLOYMENT_GROUP" \
    --description "$description" \
    --revision "$revision" \
    --query deploymentId --output text
}

promote_image "$STAGING_API_ECR_REPOSITORY" "$PRODUCTION_API_ECR_REPOSITORY"
promote_image "$STAGING_WORKER_ECR_REPOSITORY" "$PRODUCTION_WORKER_ECR_REPOSITORY"

registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
api_image="${registry}/${PRODUCTION_API_ECR_REPOSITORY}:${IMAGE_TAG}"
worker_image="${registry}/${PRODUCTION_WORKER_ECR_REPOSITORY}:${IMAGE_TAG}"
previous_api_task=$(aws ecs describe-task-sets --cluster "$ECS_CLUSTER" --service "$API_ECS_SERVICE" --query "taskSets[?status=='PRIMARY'].taskDefinition | [0]" --output text)
previous_worker_task=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$WORKER_ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
[[ "$previous_api_task" == arn:* && "$previous_worker_task" == arn:* ]]

aws ecs describe-task-definition --task-definition "$previous_api_task" --query taskDefinition --output json | jq --arg image "$api_image" 'del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy,.deregisteredAt) | (.containerDefinitions[] | select(.name == "api") | .image) = $image' > api-task-definition.json
aws ecs describe-task-definition --task-definition "$previous_worker_task" --query taskDefinition --output json | jq --arg image "$worker_image" 'del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy,.deregisteredAt) | (.containerDefinitions[] | select(.name == "worker") | .image) = $image' > worker-task-definition.json
new_api_task=$(aws ecs register-task-definition --cli-input-json file://api-task-definition.json --query taskDefinition.taskDefinitionArn --output text)
new_worker_task=$(aws ecs register-task-definition --cli-input-json file://worker-task-definition.json --query taskDefinition.taskDefinitionArn --output text)

worker_started=false
api_deployment_id=""
api_deployment_succeeded=false
canary_probe_pid=""
rollback() {
  local exit_code=$?
  trap - ERR
  echo "Production verification failed; restoring the previous release" >&2
  if [[ -n "$canary_probe_pid" ]]; then
    kill "$canary_probe_pid" >/dev/null 2>&1 || true
    wait "$canary_probe_pid" 2>/dev/null || true
  fi
  if [[ -n "$api_deployment_id" && "$api_deployment_succeeded" == false ]]; then
    aws deploy stop-deployment --deployment-id "$api_deployment_id" --auto-rollback-enabled >/dev/null || true
  elif [[ "$api_deployment_succeeded" == true ]]; then
    rollback_deployment_id=$(create_api_deployment "$previous_api_task" "Rollback failed production verification for ${IMAGE_TAG}") || true
    [[ -z "${rollback_deployment_id:-}" ]] || aws deploy wait deployment-successful --deployment-id "$rollback_deployment_id" || true
  fi
  if [[ "$worker_started" == true ]]; then
    aws ecs update-service --cluster "$ECS_CLUSTER" --service "$WORKER_ECS_SERVICE" --task-definition "$previous_worker_task" >/dev/null || true
    aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$WORKER_ECS_SERVICE" || true
  fi
  exit "$exit_code"
}
trap rollback ERR

worker_started=true
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$WORKER_ECS_SERVICE" --task-definition "$new_worker_task" >/dev/null
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$WORKER_ECS_SERVICE"
active_worker_task=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$WORKER_ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
[[ "$active_worker_task" == "$new_worker_task" ]] || { echo "Worker circuit breaker restored its previous revision" >&2; false; }

api_deployment_id=$(create_api_deployment "$new_api_task" "Production canary for ${IMAGE_TAG}")
[[ "$api_deployment_id" == d-* ]] || { echo "CodeDeploy did not return a deployment ID" >&2; false; }
api_origin=${API_URL%/}
(
  while true; do
    curl --max-time 10 --silent --show-error "${api_origin}/health" >/dev/null || true
    curl --max-time 20 --silent --show-error "${auth_header[@]}" -H 'Content-Type: application/json' -d '{"prompt":"Reply with exactly CANARY and nothing else."}' "${api_origin}/v1/generate" >/dev/null || true
    sleep 15
  done
) &
canary_probe_pid=$!
aws deploy wait deployment-successful --deployment-id "$api_deployment_id"
kill "$canary_probe_pid" >/dev/null 2>&1 || true
wait "$canary_probe_pid" 2>/dev/null || true
canary_probe_pid=""
api_deployment_succeeded=true
active_api_task=$(aws ecs describe-task-sets --cluster "$ECS_CLUSTER" --service "$API_ECS_SERVICE" --query "taskSets[?status=='PRIMARY'].taskDefinition | [0]" --output text)
[[ "$active_api_task" == "$new_api_task" ]] || { echo "CodeDeploy did not promote the expected task definition" >&2; false; }

health=$(curl --fail --silent --show-error "${api_origin}/health")
[[ "$(jq -r '.status' <<<"$health")" == "ok" && "$(jq -r '.environment' <<<"$health")" == "production" ]]
curl --fail --silent --show-error "${api_origin}/ready" | jq -e '.status == "ready"' >/dev/null
unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/json' -d '{"prompt":"must be rejected"}' "${api_origin}/v1/generate")
[[ "$unauthenticated_status" == "401" ]] || { echo "Production inference endpoint accepted an unauthenticated request" >&2; false; }
python -m evals.run_remote_eval --base-url "$api_origin"

job_id=$(curl --fail --silent --show-error "${auth_header[@]}" -H 'Content-Type: application/json' -d '{"prompt":"production worker release verification"}' "${api_origin}/v1/jobs" | jq -er '.job_id')
job_succeeded=false
for attempt in {1..36}; do
  job=$(curl --fail --silent --show-error "${auth_header[@]}" "${api_origin}/v1/jobs/${job_id}")
  case "$(jq -r '.status' <<<"$job")" in
    succeeded) jq -e '.output | type == "string" and length > 0' <<<"$job" >/dev/null; job_succeeded=true; break ;;
    failed) echo "Production asynchronous inference failed" >&2; false ;;
  esac
  sleep 5
done
[[ "$job_succeeded" == true ]] || { echo "Production asynchronous inference timed out" >&2; false; }

trap - ERR
echo "Production release ${IMAGE_TAG} completed through canary ${api_deployment_id}"
