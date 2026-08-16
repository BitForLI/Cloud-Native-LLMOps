import re
from pathlib import Path

import yaml

GITHUB_DIR = Path(__file__).parents[1]
WORKFLOW_PATH = GITHUB_DIR / "workflows" / "release-production.yml"
SCRIPT_PATH = GITHUB_DIR / "scripts" / "promote-production.sh"


def load_workflow():
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_release_is_manual_serialized_and_protected():
    workflow = load_workflow()
    job = workflow["jobs"]["release"]

    assert workflow["run-name"] == "Release Production ${{ inputs.image_tag }}"
    assert workflow["on"]["workflow_dispatch"]["inputs"]["image_tag"]["required"] == "true"
    assert workflow["concurrency"]["cancel-in-progress"] == "false"
    assert job["if"] == "github.ref == 'refs/heads/master'"
    assert job["environment"] == "production"
    assert job["permissions"] == {
        "actions": "read",
        "contents": "read",
        "id-token": "write",
    }


def test_release_requires_successful_staging_and_pins_actions():
    job = load_workflow()["jobs"]["release"]
    scripts = "\n".join(step.get("run", "") for step in job["steps"])
    actions = [step["uses"] for step in job["steps"] if "uses" in step]

    assert "promote-staging.yml/runs" in scripts
    assert "Promote Staging ${IMAGE_TAG}" in scripts
    assert "Staging promotion job did not succeed" in scripts
    assert "performance-staging.yml/runs" in scripts
    assert "Staging Performance ${IMAGE_TAG}" in scripts
    assert "Staging performance job did not succeed" in scripts
    assert actions and all(re.search(r"@[0-9a-f]{40}$", action) for action in actions)


def test_release_promotes_digest_uses_codedeploy_and_recovers_both_services():
    script = SCRIPT_PATH.read_text(encoding="utf-8")

    for fragment in (
        "batch-get-image",
        '[[ "$destination_digest" == "$source_digest" ]]',
        "findingSeverityCounts.CRITICAL",
        "findingSeverityCounts.HIGH",
        "create_api_deployment",
        "aws deploy wait deployment-successful",
        "Reply with exactly CANARY",
        "stop-deployment",
        "Rollback failed production verification",
        'taskSets[?status==\'PRIMARY\']',
        "Worker circuit breaker restored",
        "python -m evals.run_remote_eval",
        "secretsmanager get-secret-value",
        "::add-mask::",
        'X-API-Key: ${API_AUTH_TOKEN}',
        'unauthenticated_status" == "401',
        '"${api_origin}/v1/jobs/${job_id}"',
    ):
        assert fragment in script


def test_release_configuration_is_complete():
    environment = load_workflow()["jobs"]["release"]["env"]

    assert {
        "STAGING_API_ECR_REPOSITORY",
        "STAGING_WORKER_ECR_REPOSITORY",
        "PRODUCTION_API_ECR_REPOSITORY",
        "PRODUCTION_WORKER_ECR_REPOSITORY",
        "ECS_CLUSTER",
        "API_ECS_SERVICE",
        "WORKER_ECS_SERVICE",
        "API_URL",
        "API_AUTH_SECRET_ID",
        "CODEDEPLOY_APPLICATION",
        "CODEDEPLOY_DEPLOYMENT_GROUP",
        "IMAGE_TAG",
    }.issubset(environment)
