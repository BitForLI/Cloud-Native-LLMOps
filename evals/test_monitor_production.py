import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from evals.models import Prediction
from evals.monitor_production import METRIC_NAMESPACE, run_monitor


class RecordingClient:
    def __init__(self):
        self.calls: list[dict] = []

    def put_metric_data(self, **kwargs):
        self.calls.append(kwargs)

    def put_object(self, **kwargs):
        self.calls.append(kwargs)


class FailingEvidenceClient(RecordingClient):
    def put_object(self, **kwargs):
        raise RuntimeError("evidence unavailable")


def _dataset(tmp_path: Path, expected: str = "expected") -> Path:
    path = tmp_path / "dataset.json"
    path.write_text(
        json.dumps([{"id": "case-1", "prompt": "prompt", "expected_output": expected}]),
        encoding="utf-8",
    )
    return path


def test_monitor_publishes_metrics_and_immutable_evidence(tmp_path: Path):
    dataset = _dataset(tmp_path)
    cloudwatch = RecordingClient()
    s3 = RecordingClient()
    evaluated_at = datetime(2026, 8, 16, 3, 17, tzinfo=UTC)

    result = run_monitor(
        base_url="https://production.example.com",
        artifact_bucket="llmops-production-artifacts",
        environment="production",
        revision="a" * 40,
        run_id="12345",
        run_attempt=2,
        dataset_path=dataset,
        predictor=lambda _prompt: Prediction(output="expected", estimated_cost_usd=0.01),
        cloudwatch_client=cloudwatch,
        s3_client=s3,
        now=evaluated_at,
    )

    assert result == 0
    metric_call = cloudwatch.calls[0]
    assert metric_call["Namespace"] == METRIC_NAMESPACE
    metrics = {metric["MetricName"]: metric for metric in metric_call["MetricData"]}
    assert metrics["EvaluationAccuracy"]["Value"] == 1.0
    assert metrics["EvaluationPass"]["Value"] == 1.0
    assert metrics["EvaluationEstimatedCostUSD"]["Value"] == 0.01
    assert all(
        metric["Dimensions"]
        == [
            {"Name": "Environment", "Value": "production"},
            {"Name": "Service", "Value": "evaluation"},
        ]
        for metric in metrics.values()
    )

    object_call = s3.calls[0]
    assert object_call["IfNoneMatch"] == "*"
    assert object_call["ServerSideEncryption"] == "AES256"
    assert object_call["Key"] == f"evaluations/production/2026/08/16/12345-2-{'a' * 40}.json"
    evidence = json.loads(object_call["Body"])
    assert evidence["dataset_sha256"] == hashlib.sha256(dataset.read_bytes()).hexdigest()
    assert evidence["report"]["overall_status"] == "PASS"
    assert "prompt" not in evidence and "api_token" not in evidence


def test_monitor_persists_failed_gate_before_returning_failure(tmp_path: Path):
    cloudwatch = RecordingClient()
    s3 = RecordingClient()
    result = run_monitor(
        base_url="https://production.example.com",
        artifact_bucket="llmops-production-artifacts",
        environment="production",
        revision="b" * 40,
        run_id="7",
        run_attempt=1,
        dataset_path=_dataset(tmp_path),
        predictor=lambda _prompt: Prediction(output="regressed", estimated_cost_usd=0),
        cloudwatch_client=cloudwatch,
        s3_client=s3,
        now=datetime(2026, 8, 16, tzinfo=UTC),
    )

    assert result == 1
    pass_metric = next(
        metric for metric in cloudwatch.calls[0]["MetricData"] if metric["MetricName"] == "EvaluationPass"
    )
    assert pass_metric["Value"] == 0.0
    assert json.loads(s3.calls[0]["Body"])["report"]["overall_status"] == "FAIL"


def test_monitor_does_not_report_success_when_evidence_write_fails(tmp_path: Path):
    cloudwatch = RecordingClient()
    with pytest.raises(RuntimeError, match="evidence unavailable"):
        run_monitor(
            base_url="https://production.example.com",
            artifact_bucket="llmops-production-artifacts",
            environment="production",
            revision="c" * 40,
            run_id="8",
            run_attempt=1,
            dataset_path=_dataset(tmp_path),
            predictor=lambda _prompt: Prediction(output="expected"),
            cloudwatch_client=cloudwatch,
            s3_client=FailingEvidenceClient(),
            now=datetime(2026, 8, 16, tzinfo=UTC),
        )

    assert cloudwatch.calls == []


@pytest.mark.parametrize(
    ("revision", "run_id", "attempt"),
    [("short", "1", 1), ("a" * 40, "0", 1), ("a" * 40, "1", 0)],
)
def test_monitor_rejects_ambiguous_evidence_identity(
    tmp_path: Path, revision: str, run_id: str, attempt: int
):
    with pytest.raises(ValueError):
        run_monitor(
            base_url="https://production.example.com",
            artifact_bucket="llmops-production-artifacts",
            environment="production",
            revision=revision,
            run_id=run_id,
            run_attempt=attempt,
            dataset_path=_dataset(tmp_path),
            predictor=lambda _: Prediction(output="expected"),
            cloudwatch_client=RecordingClient(),
            s3_client=RecordingClient(),
        )
