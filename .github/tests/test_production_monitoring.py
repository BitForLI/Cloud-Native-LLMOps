import re
from pathlib import Path

import yaml

WORKFLOW_PATH = Path(__file__).parents[1] / "workflows" / "monitor-production-eval.yml"


def load_workflow():
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_monitor_is_manual_serialized_and_isolated():
    workflow = load_workflow()
    job = workflow["jobs"]["evaluate"]

    assert "schedule" not in workflow["on"]
    assert "workflow_dispatch" in workflow["on"]
    assert workflow["concurrency"] == {
        "group": "monitor-production-evaluation",
        "cancel-in-progress": "false",
    }
    assert job["if"] == "github.ref == 'refs/heads/master'"
    assert job["environment"] == "production-monitoring"
    assert job["permissions"] == {"contents": "read", "id-token": "write"}


def test_monitor_pins_actions_masks_secret_and_runs_publisher():
    job = load_workflow()["jobs"]["evaluate"]
    scripts = "\n".join(step.get("run", "") for step in job["steps"])
    actions = [step["uses"] for step in job["steps"] if "uses" in step]

    assert actions and all(re.search(r"@[0-9a-f]{40}$", action) for action in actions)
    assert "secretsmanager get-secret-value" in scripts
    assert "::add-mask::$token" in scripts
    assert "python -m evals.monitor_production" in scripts
    assert "--run-attempt" in scripts
    assert "aws ecs" not in scripts
    assert "aws ecr" not in scripts
    assert "codedeploy" not in scripts.lower()


def test_monitor_configuration_is_complete_and_non_secret():
    environment = load_workflow()["jobs"]["evaluate"]["env"]

    assert set(environment) == {
        "API_AUTH_SECRET_ID",
        "API_URL",
        "ARTIFACT_BUCKET",
        "AWS_ACCOUNT_ID",
        "AWS_EVALUATION_ROLE_ARN",
        "AWS_PAGER",
        "AWS_REGION",
    }
    assert "EVAL_API_TOKEN" not in environment
