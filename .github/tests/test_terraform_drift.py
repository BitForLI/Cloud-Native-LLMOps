import re
import sys
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import pytest
import yaml

GITHUB_DIR = Path(__file__).parents[1]
SCRIPT_PATH = GITHUB_DIR / "scripts" / "summarize_terraform_plan.py"
WORKFLOW_PATH = GITHUB_DIR / "workflows" / "drift-production.yml"
SPEC = spec_from_file_location("summarize_terraform_plan", SCRIPT_PATH)
assert SPEC and SPEC.loader
summarizer = module_from_spec(SPEC)
sys.modules[SPEC.name] = summarizer
SPEC.loader.exec_module(summarizer)


def test_plan_summary_contains_actions_and_policies_but_no_values():
    plan = {
        "resource_changes": [
            {
                "address": "module.iam.aws_iam_role.api",
                "mode": "managed",
                "type": "aws_iam_role",
                "provider_name": "registry.terraform.io/hashicorp/aws",
                "change": {
                    "actions": ["update"],
                    "before": {"policy": "sensitive-old-value"},
                    "after": {"policy": "sensitive-new-value"},
                },
            },
            {
                "address": "module.database.aws_s3_bucket.artifacts",
                "mode": "managed",
                "type": "aws_s3_bucket",
                "provider_name": "registry.terraform.io/hashicorp/aws",
                "change": {"actions": ["delete", "create"]},
            },
        ]
    }

    report = summarizer.summarize(plan, "drift", "a" * 40)
    rendered = str(report)

    assert report["passed"] is False
    assert report["summary"]["changed_resources"] == 2
    assert report["summary"]["actions"] == {"create": 1, "delete": 1, "update": 1}
    assert report["summary"]["policy_findings"]["destructive_change"] == 1
    assert "identity_boundary_change" in rendered
    assert "data_protection_change" in rendered
    assert "sensitive-old-value" not in rendered
    assert "sensitive-new-value" not in rendered
    assert "before" not in rendered and "after" not in rendered


def test_no_op_and_read_only_data_sources_are_not_drift():
    plan = {
        "resource_changes": [
            {"address": "aws_vpc.main", "change": {"actions": ["no-op"]}},
            {"address": "data.aws_region.current", "change": {"actions": ["read"]}},
        ]
    }

    report = summarizer.summarize(plan, "clean", "b" * 40)

    assert report["passed"] is True
    assert report["changes"] == []


def test_output_only_plan_is_reported_without_exposing_output_values():
    plan = {
        "output_changes": {
            "api_url": {
                "actions": ["update"],
                "before": "https://sensitive-old.example",
                "after": "https://sensitive-new.example",
            }
        }
    }

    report = summarizer.summarize(plan, "drift", "d" * 40)
    rendered = str(report)

    assert report["summary"]["changed_resources"] == 0
    assert report["summary"]["changed_outputs"] == 1
    assert report["output_changes"] == [{"name": "api_url", "actions": ["update"]}]
    assert "sensitive-old" not in rendered and "sensitive-new" not in rendered


@pytest.mark.parametrize(
    ("status", "plan", "message"),
    [
        ("clean", {"resource_changes": [{"address": "x", "change": {"actions": ["update"]}}]}, "clean status"),
        ("drift", {"resource_changes": [], "output_changes": {}}, "drift status"),
        ("unsupported", {}, "unsupported plan status"),
    ],
)
def test_inconsistent_or_unknown_plan_status_is_rejected(status, plan, message):
    with pytest.raises(ValueError, match=message):
        summarizer.summarize(plan, status, "c" * 40)


def test_workflow_is_manual_protected_read_only_and_retains_sanitized_evidence():
    workflow = yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    job = workflow["jobs"]["audit"]
    scripts = "\n".join(step.get("run", "") for step in job["steps"])
    actions = [step["uses"] for step in job["steps"] if "uses" in step]

    assert "schedule" not in workflow["on"]
    assert "workflow_dispatch" in workflow["on"]
    assert job["environment"] == "production-drift"
    assert job["permissions"] == {"contents": "read", "id-token": "write"}
    assert "-detailed-exitcode" in scripts
    assert "-lock=false" in scripts
    assert "summarize_terraform_plan.py" in scripts
    assert "InfrastructureDriftDetected" in scripts
    assert "InfrastructureDriftAuditHeartbeat" in scripts
    assert actions and all(re.search(r"@[0-9a-f]{40}$", action) for action in actions)
    assert job["env"]["PRODUCTION_TFVARS_JSON"] == (
        "${{ secrets.PRODUCTION_TFVARS_JSON }}"
    )
    evidence = next(step for step in job["steps"] if step["name"] == "Retain sanitized drift evidence")
    assert evidence["if"] == "always()"
    assert evidence["with"]["path"] == "artifacts/production-drift-report.json"
    assert evidence["with"]["retention-days"] == "90"
    assert "production-plan-values.json" not in evidence["with"]["path"]
