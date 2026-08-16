import importlib.util
import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

import yaml
from botocore.exceptions import ClientError

GITHUB_DIR = Path(__file__).parents[1]
WORKFLOW_PATH = GITHUB_DIR / "workflows" / "diagnose-production.yml"
COLLECTOR_PATH = GITHUB_DIR / "scripts" / "collect_production_diagnostics.py"
RUNBOOK_DIR = GITHUB_DIR.parent / "docs" / "runbooks"


def load_workflow():
    return yaml.load(WORKFLOW_PATH.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def load_collector():
    spec = importlib.util.spec_from_file_location("incident_collector", COLLECTOR_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeClient:
    def __init__(self, service, fail_service=None):
        self.service = service
        self.fail_service = fail_service

    def _fail(self):
        if self.service == self.fail_service:
            raise ClientError(
                {"Error": {"Code": "AccessDeniedException", "Message": "denied"}},
                "ReadOnlyProbe",
            )

    def describe_services(self, **_):
        self._fail()
        return {
            "services": [
                {
                    "serviceName": "prod-api",
                    "status": "ACTIVE",
                    "desiredCount": 3,
                    "runningCount": 3,
                    "pendingCount": 0,
                    "taskDefinition": "task:1",
                    "deployments": [],
                    "events": [],
                }
            ],
            "failures": [],
        }

    def describe_alarms(self, **_):
        self._fail()
        return {"MetricAlarms": [{"AlarmName": "prod-api-errors", "StateValue": "OK"}]}

    def get_queue_attributes(self, **_):
        self._fail()
        return {"Attributes": {"ApproximateNumberOfMessages": "0"}}

    def get_trail_status(self, **_):
        self._fail()
        return {"IsLogging": True, "LatestDeliveryTime": datetime(2026, 1, 1, tzinfo=UTC)}

    def describe_backup_vault(self, **_):
        self._fail()
        return {"BackupVaultName": "prod-recovery", "Locked": True, "NumberOfRecoveryPoints": 4}

    def list_backup_jobs(self, **_):
        self._fail()
        return {"BackupJobs": [{"BackupJobId": "backup-1", "State": "COMPLETED"}]}

    def list_restore_jobs(self, **_):
        self._fail()
        return {"RestoreJobs": [{"RestoreJobId": "restore-1", "Status": "COMPLETED"}]}

    def get_deployment_group(self, **_):
        self._fail()
        return {
            "deploymentGroupInfo": {
                "applicationName": "prod",
                "deploymentGroupName": "prod-api",
                "deploymentConfigName": "CodeDeployDefault.ECSCanary10Percent5Minutes",
            }
        }


class FakeSession:
    def __init__(self, fail_service=None):
        self.fail_service = fail_service

    def client(self, service):
        return FakeClient(service, self.fail_service)


def collector_arguments(output):
    return [
        "collector",
        "--incident-id",
        "INC-2026-001",
        "--lookback-hours",
        "6",
        "--region",
        "ap-southeast-2",
        "--cluster",
        "prod",
        "--api-service",
        "prod-api",
        "--worker-service",
        "prod-worker",
        "--inference-queue-url",
        "https://sqs.example/inference",
        "--dead-letter-queue-url",
        "https://sqs.example/dlq",
        "--alarm-name-prefix",
        "prod",
        "--audit-trail-name",
        "prod-management",
        "--backup-vault-name",
        "prod-recovery",
        "--restore-testing-plan-arn",
        "arn:aws:backup:ap-southeast-2:123456789012:restore-testing-plan:prod",
        "--codedeploy-application",
        "prod",
        "--codedeploy-deployment-group",
        "prod-api",
        "--output",
        str(output),
    ]


def test_collector_writes_sanitized_complete_report(monkeypatch, tmp_path):
    collector = load_collector()
    output = tmp_path / "diagnostics.json"
    monkeypatch.setattr(collector.boto3, "Session", lambda **_: FakeSession())
    monkeypatch.setattr(sys, "argv", collector_arguments(output))

    assert collector.main() == 0
    report = json.loads(output.read_text(encoding="utf-8"))
    assert set(report["probes"]) == {
        "ecs_services",
        "cloudwatch_alarms",
        "inference_queue",
        "dead_letter_queue",
        "cloudtrail",
        "backup",
        "codedeploy",
    }
    assert report["errors"] == []
    serialized = json.dumps(report)
    assert "SecretString" not in serialized
    assert "GetSecretValue" not in serialized
    assert "prompt" not in serialized.lower()


def test_collector_preserves_partial_evidence_and_fails_closed(monkeypatch, tmp_path):
    collector = load_collector()
    output = tmp_path / "diagnostics.json"
    monkeypatch.setattr(
        collector.boto3,
        "Session",
        lambda **_: FakeSession(fail_service="cloudtrail"),
    )
    monkeypatch.setattr(sys, "argv", collector_arguments(output))

    assert collector.main() == 1
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["errors"] == ["cloudtrail"]
    assert report["probes"]["cloudtrail"] == {
        "ok": False,
        "error_code": "AccessDeniedException",
    }
    assert report["probes"]["ecs_services"]["ok"]


def test_workflow_is_manual_protected_pinned_and_read_only():
    workflow = load_workflow()
    job = workflow["jobs"]["diagnose"]
    scripts = "\n".join(step.get("run", "") for step in job["steps"])
    actions = [step["uses"] for step in job["steps"] if "uses" in step]

    assert workflow["concurrency"] == {
        "group": "production-diagnostics",
        "cancel-in-progress": "false",
    }
    assert job["environment"] == "production-operations"
    assert job["if"] == "github.ref == 'refs/heads/master'"
    assert job["permissions"] == {"contents": "read", "id-token": "write"}
    assert actions and all(re.search(r"@[0-9a-f]{40}$", action) for action in actions)
    assert "AWS_OPERATIONS_ROLE_ARN" in job["env"]
    assert "API_AUTH_SECRET_ID" not in job["env"]
    assert "RESTORE_TESTING_PLAN_ARN" in job["env"]
    assert "secretsmanager" not in scripts
    assert "update-service" not in scripts
    assert "create-deployment" not in scripts
    assert "production-diagnostics.json" in scripts


def test_runbooks_cover_required_operational_decisions():
    runbooks = sorted(RUNBOOK_DIR.glob("*.md"))
    assert len(runbooks) >= 4
    combined = "\n".join(path.read_text(encoding="utf-8") for path in runbooks)
    for heading in (
        "## Trigger",
        "## Diagnosis",
        "## Containment",
        "## Recovery",
        "## Validation",
        "## Evidence",
    ):
        assert heading in combined
    for concept in (
        "CodeDeploy",
        "dead-letter",
        "Bedrock",
        "restore testing",
        "production-diagnostics.json",
    ):
        assert concept in combined
