"""Continuously evaluate production and publish immutable operational evidence."""

import argparse
import base64
import hashlib
import json
import os
import re
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from evals.config import EvalConfig
from evals.models import EvalReport, Prediction
from evals.run_eval import load_dataset, run_evaluation
from evals.run_remote_eval import REMOTE_DATASET, remote_predictor

METRIC_NAMESPACE = "CloudNativeLLMOps"
SERVICE_DIMENSION = "evaluation"


def _validate_metadata(
    environment: str, revision: str, run_id: str, run_attempt: int
) -> None:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,31}", environment):
        raise ValueError("environment must be 2-32 lowercase characters or hyphens")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full lowercase commit SHA")
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("run_id must be a positive integer")
    if run_attempt < 1:
        raise ValueError("run_attempt must be positive")


def _dataset_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _evidence(
    report: EvalReport,
    dataset_path: Path,
    environment: str,
    revision: str,
    run_id: str,
    run_attempt: int,
    evaluated_at: datetime,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "evaluated_at": evaluated_at.isoformat().replace("+00:00", "Z"),
        "environment": environment,
        "revision": revision,
        "github_run_id": run_id,
        "github_run_attempt": run_attempt,
        "dataset_sha256": _dataset_digest(dataset_path),
        "report": report.to_dict(),
    }


def _metric_data(report: EvalReport, environment: str, timestamp: datetime) -> list[dict[str, Any]]:
    dimensions = [
        {"Name": "Environment", "Value": environment},
        {"Name": "Service", "Value": SERVICE_DIMENSION},
    ]
    values: list[tuple[str, float, str]] = [
        ("EvaluationAccuracy", report.accuracy, "None"),
        ("EvaluationP95LatencyMs", report.p95_latency_ms, "Milliseconds"),
        ("EvaluationPass", 1.0 if report.overall_status == "PASS" else 0.0, "Count"),
    ]
    if report.estimated_cost_usd is not None:
        values.append(("EvaluationEstimatedCostUSD", report.estimated_cost_usd, "None"))
    return [
        {
            "MetricName": name,
            "Dimensions": dimensions,
            "Timestamp": timestamp,
            "Value": value,
            "Unit": unit,
            "StorageResolution": 60,
        }
        for name, value, unit in values
    ]


def run_monitor(
    base_url: str,
    artifact_bucket: str,
    environment: str,
    revision: str,
    run_id: str,
    run_attempt: int,
    dataset_path: Path = REMOTE_DATASET,
    api_token: str | None = None,
    predictor: Callable[[str], Prediction] | None = None,
    cloudwatch_client: Any | None = None,
    s3_client: Any | None = None,
    now: datetime | None = None,
) -> int:
    """Run the gate, publish metrics, and conditionally persist its evidence."""

    _validate_metadata(environment, revision, run_id, run_attempt)
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", artifact_bucket):
        raise ValueError("artifact_bucket must be a valid lowercase S3 bucket name")

    evaluated_at = now or datetime.now(UTC)
    if evaluated_at.tzinfo is None or evaluated_at.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    active_predictor = predictor or remote_predictor(
        base_url, api_token if api_token is not None else os.getenv("EVAL_API_TOKEN", "")
    )
    _, report = run_evaluation(
        load_dataset(dataset_path), active_predictor, EvalConfig.from_env()
    )
    evidence = _evidence(
        report,
        dataset_path,
        environment,
        revision,
        run_id,
        run_attempt,
        evaluated_at,
    )
    body = (json.dumps(evidence, indent=2, sort_keys=True) + "\n").encode("utf-8")
    key = (
        f"evaluations/{environment}/{evaluated_at:%Y/%m/%d}/"
        f"{run_id}-{run_attempt}-{revision}.json"
    )

    if cloudwatch_client is None or s3_client is None:
        import boto3

    cloudwatch = cloudwatch_client or boto3.client("cloudwatch")
    s3 = s3_client or boto3.client("s3")
    s3.put_object(
        Bucket=artifact_bucket,
        Key=key,
        Body=body,
        ContentType="application/json",
        ServerSideEncryption="AES256",
        ChecksumSHA256=base64.b64encode(hashlib.sha256(body).digest()).decode("ascii"),
        IfNoneMatch="*",
    )
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=_metric_data(report, environment, evaluated_at),
    )

    print(json.dumps({"evidence_key": key, "report": report.to_dict()}, sort_keys=True))
    return 0 if report.overall_status == "PASS" else 1


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--artifact-bucket", required=True)
    parser.add_argument("--environment", default="production")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True, type=int)
    parser.add_argument("--dataset", type=Path, default=REMOTE_DATASET)
    args = parser.parse_args(argv)
    raise SystemExit(
        run_monitor(
            base_url=args.base_url,
            artifact_bucket=args.artifact_bucket,
            environment=args.environment,
            revision=args.revision,
            run_id=args.run_id,
            run_attempt=args.run_attempt,
            dataset_path=args.dataset,
        )
    )


if __name__ == "__main__":
    main()
