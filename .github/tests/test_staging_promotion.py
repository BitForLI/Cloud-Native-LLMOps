import re
from pathlib import Path

import yaml

GITHUB_DIR = Path(__file__).parents[1]
WORKFLOW_PATH = GITHUB_DIR / "workflows" / "promote-staging.yml"
SCRIPT_PATH = GITHUB_DIR / "scripts" / "promote-staging.sh"


def load_workflow():
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_staging_is_manual_serialized_and_environment_protected():
    workflow = load_workflow()
    job = workflow["jobs"]["promote"]

    assert workflow["on"]["workflow_dispatch"]["inputs"]["image_tag"]["required"] == "true"
    assert workflow["concurrency"] == {
        "group": "promote-staging",
        "cancel-in-progress": "false",
    }
    assert job["environment"] == "staging"
    assert job["if"] == "github.ref == 'refs/heads/master'"
    assert job["permissions"] == {
        "actions": "read",
        "contents": "read",
        "id-token": "write",
    }


def test_staging_requires_successful_ci_and_pins_actions():
    workflow = load_workflow()
    job = workflow["jobs"]["promote"]
    scripts = "\n".join(step.get("run", "") for step in job["steps"])
    actions = [step["uses"] for step in job["steps"] if "uses" in step]

    assert "--method GET" in scripts
    assert "head_sha=\"$IMAGE_TAG\"" in scripts
    assert "branch=master" in scripts
    assert "event=push" in scripts
    assert "status=success" in scripts
    assert "deploy-dev.yml/runs" in scripts
    assert "Development deploy job did not succeed" in scripts
    assert actions and all(re.search(r"@[0-9a-f]{40}$", action) for action in actions)


def test_promotion_reuses_digest_scans_and_rolls_back_both_services():
    script = SCRIPT_PATH.read_text(encoding="utf-8")

    for fragment in (
        "batch-get-image",
        "source_digest",
        '[[ "$destination_digest" == "$source_digest" ]]',
        "findingSeverityCounts.CRITICAL",
        "findingSeverityCounts.HIGH",
        "register-task-definition",
        "aws ecs wait services-stable",
        "restoring both previous task definitions",
        '"${api_origin}/ready"',
        '"${api_origin}/v1/generate"',
        "python -m evals.run_remote_eval",
        '"${api_origin}/v1/jobs"',
        '"${api_origin}/v1/jobs/${job_id}"',
    ):
        assert fragment in script


def test_promotion_configuration_is_complete():
    environment = load_workflow()["jobs"]["promote"]["env"]

    assert {
        "DEV_API_ECR_REPOSITORY",
        "DEV_WORKER_ECR_REPOSITORY",
        "STAGING_API_ECR_REPOSITORY",
        "STAGING_WORKER_ECR_REPOSITORY",
        "ECS_CLUSTER",
        "API_ECS_SERVICE",
        "WORKER_ECS_SERVICE",
        "API_URL",
        "IMAGE_TAG",
    }.issubset(environment)
