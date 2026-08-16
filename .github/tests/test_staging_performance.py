import re
from pathlib import Path

import yaml

WORKFLOW_PATH = Path(__file__).parents[1] / "workflows" / "performance-staging.yml"


def load_workflow():
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_performance_gate_is_manual_serialized_and_staging_protected():
    workflow = load_workflow()
    job = workflow["jobs"]["performance"]
    inputs = workflow["on"]["workflow_dispatch"]["inputs"]

    assert set(inputs) == {
        "image_tag",
        "duration_seconds",
        "requests_per_second",
        "concurrency",
    }
    assert all(value["required"] == "true" for value in inputs.values())
    assert workflow["concurrency"] == {
        "group": "staging-performance",
        "cancel-in-progress": "false",
    }
    assert job["environment"] == "staging"
    assert job["if"] == "github.ref == 'refs/heads/master'"
    assert job["permissions"] == {
        "actions": "read",
        "contents": "read",
        "id-token": "write",
    }


def test_performance_gate_requires_promoted_and_current_exact_revision():
    workflow = load_workflow()
    scripts = "\n".join(
        step.get("run", "") for step in workflow["jobs"]["performance"]["steps"]
    )

    for fragment in (
        "promote-staging.yml/runs",
        "status=success",
        "Promote Staging ${IMAGE_TAG}",
        "aws ecs describe-services",
        "aws ecs describe-task-definition",
        '[[ "$deployed_image" == *":${IMAGE_TAG}" ]]',
        '"${API_URL%/}/health"',
        '"${API_URL%/}/ready"',
    ):
        assert fragment in scripts


def test_performance_gate_is_bounded_secret_safe_and_supply_chain_pinned():
    workflow = load_workflow()
    steps = workflow["jobs"]["performance"]["steps"]
    scripts = "\n".join(step.get("run", "") for step in steps)
    actions = [step["uses"] for step in steps if "uses" in step]

    assert actions and all(re.search(r"@[0-9a-f]{40}$", action) for action in actions)
    assert "DURATION_SECONDS >= 30" in scripts
    assert "DURATION_SECONDS <= 900" in scripts
    assert "LOAD_CONCURRENCY <= 200" in scripts
    assert "secretsmanager get-secret-value" in scripts
    assert "::add-mask::" in scripts
    assert "export API_AUTH_TOKEN" in scripts
    assert "--max-error-rate 0.01" in scripts
    assert "--max-p95-latency-ms 3000" in scripts
    assert "--min-throughput-ratio 0.90" in scripts
    assert "load-test-report.json" in scripts


def test_performance_report_is_always_retained_without_secret_inputs():
    workflow = load_workflow()
    job = workflow["jobs"]["performance"]
    upload = next(step for step in job["steps"] if step["name"].startswith("Upload"))

    assert upload["if"] == "always()"
    assert upload["with"]["path"] == "load-test-report.json"
    assert upload["with"]["retention-days"] == "30"
    assert "API_AUTH_TOKEN" not in job["env"]
