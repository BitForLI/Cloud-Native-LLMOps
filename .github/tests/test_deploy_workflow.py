import re
from pathlib import Path

import yaml

WORKFLOW_PATH = Path(__file__).parents[1] / "workflows" / "deploy-dev.yml"


def load_workflow():
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_deploy_runs_only_after_successful_main_push_ci():
    workflow = load_workflow()
    trigger = workflow["on"]["workflow_run"]
    job = workflow["jobs"]["deploy"]

    assert trigger == {
        "workflows": ["CI"],
        "branches": ["master"],
        "types": ["completed"],
    }
    assert "conclusion == 'success'" in job["if"]
    assert "workflow_run.event == 'push'" in job["if"]
    assert "head_branch == 'master'" in job["if"]
    assert "vars.AWS_DEPLOY_ROLE_ARN != ''" in job["if"]
    assert workflow["concurrency"]["cancel-in-progress"] == "false"
    assert workflow["run-name"] == (
        "Deploy Development ${{ github.event.workflow_run.head_sha }}"
    )


def test_deploy_has_minimal_oidc_permissions_and_pinned_actions():
    workflow = load_workflow()
    job = workflow["jobs"]["deploy"]

    assert job["permissions"] == {"contents": "read", "id-token": "write"}
    assert "AWS_ACCESS_KEY_ID" not in WORKFLOW_PATH.read_text(encoding="utf-8")
    uses = [step["uses"] for step in job["steps"] if "uses" in step]
    assert uses
    assert all(re.search(r"@[0-9a-f]{40}$", action) for action in uses)


def test_deploy_checks_exact_revision_images_scans_health_and_rollback():
    workflow = load_workflow()
    job = workflow["jobs"]["deploy"]
    checkout = next(step for step in job["steps"] if "Check out" in step["name"])
    scripts = "\n".join(step.get("run", "") for step in job["steps"])

    assert checkout["with"]["ref"] == "${{ github.event.workflow_run.head_sha }}"
    assert checkout["with"]["persist-credentials"] == "false"
    for required_fragment in (
        "IMAGE_TAG must be the triggering commit SHA",
        "docker build --pull",
        "image-scan-complete",
        "findingSeverityCounts.CRITICAL",
        "findingSeverityCounts.HIGH",
        "register-task-definition",
        "aws ecs wait services-stable",
        "ECS circuit breaker rolled back at least one service",
        "restoring both previous task definitions",
        '"${api_origin}/health"',
        '"${api_origin}/ready"',
    ):
        assert required_fragment in scripts


def test_deploy_configuration_is_bounded_and_complete():
    workflow = load_workflow()
    job = workflow["jobs"]["deploy"]
    environment = job["env"]

    assert job["timeout-minutes"] == "45"
    assert {
        "AWS_ACCOUNT_ID",
        "AWS_DEPLOY_ROLE_ARN",
        "AWS_REGION",
        "API_ECR_REPOSITORY",
        "WORKER_ECR_REPOSITORY",
        "ECS_CLUSTER",
        "API_ECS_SERVICE",
        "WORKER_ECS_SERVICE",
        "API_URL",
        "IMAGE_TAG",
    }.issubset(environment)
