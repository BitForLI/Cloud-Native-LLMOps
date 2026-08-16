"""Evaluate the production ALB SLO budget before a release."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import boto3


@dataclass(frozen=True)
class SLOConfig:
    region: str
    load_balancer_suffix: str
    target_group_suffix: str
    window_hours: int
    period_seconds: int
    availability_target_percent: float
    latency_target_ms: float
    latency_compliance_target_percent: float
    minimum_requests: int

    def validate(self) -> None:
        if not self.region.strip():
            raise ValueError("region must not be empty")
        if not self.load_balancer_suffix.startswith("app/"):
            raise ValueError("load_balancer_suffix must be an ALB ARN suffix")
        if not self.target_group_suffix.startswith("targetgroup/"):
            raise ValueError("target_group_suffix must be a target-group ARN suffix")
        if not 1 <= self.window_hours <= 720:
            raise ValueError("window_hours must be between 1 and 720")
        if self.period_seconds < 60 or self.period_seconds % 60:
            raise ValueError("period_seconds must be a multiple of 60")
        if not 0 < self.availability_target_percent < 100:
            raise ValueError("availability_target_percent must be between 0 and 100")
        if self.latency_target_ms <= 0:
            raise ValueError("latency_target_ms must be positive")
        if not 0 < self.latency_compliance_target_percent < 100:
            raise ValueError(
                "latency_compliance_target_percent must be between 0 and 100"
            )
        if self.minimum_requests < 1:
            raise ValueError("minimum_requests must be positive")


def metric_queries(config: SLOConfig) -> list[dict[str, Any]]:
    lb_dimension = {"Name": "LoadBalancer", "Value": config.load_balancer_suffix}
    target_dimension = {
        "Name": "TargetGroup",
        "Value": config.target_group_suffix,
    }

    def query(
        query_id: str,
        metric_name: str,
        statistic: str,
        dimensions: list[dict[str, str]],
    ) -> dict[str, Any]:
        return {
            "Id": query_id,
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/ApplicationELB",
                    "MetricName": metric_name,
                    "Dimensions": dimensions,
                },
                "Period": config.period_seconds,
                "Stat": statistic,
            },
            "ReturnData": True,
        }

    target_dimensions = [lb_dimension, target_dimension]
    return [
        query("requests", "RequestCount", "Sum", target_dimensions),
        query("target5xx", "HTTPCode_Target_5XX_Count", "Sum", target_dimensions),
        query("elb5xx", "HTTPCode_ELB_5XX_Count", "Sum", [lb_dimension]),
        query("latencyp95", "TargetResponseTime", "p95", target_dimensions),
    ]


def collect_metrics(
    cloudwatch: Any,
    config: SLOConfig,
    start_time: datetime,
    end_time: datetime,
) -> dict[str, list[float]]:
    values: dict[str, list[float]] = {
        "requests": [],
        "target5xx": [],
        "elb5xx": [],
        "latencyp95": [],
    }
    request: dict[str, Any] = {
        "MetricDataQueries": metric_queries(config),
        "StartTime": start_time,
        "EndTime": end_time,
        "ScanBy": "TimestampAscending",
        "MaxDatapoints": 100800,
    }

    while True:
        response = cloudwatch.get_metric_data(**request)
        for result in response.get("MetricDataResults", []):
            query_id = result.get("Id")
            if query_id in values:
                values[query_id].extend(float(value) for value in result.get("Values", []))
            status = result.get("StatusCode")
            if status not in {None, "Complete"}:
                raise RuntimeError(
                    f"CloudWatch query {query_id} was not complete: {status}"
                )
        token = response.get("NextToken")
        if not token:
            return values
        request["NextToken"] = token


def evaluate_budget(
    config: SLOConfig,
    metrics: dict[str, list[float]],
    start_time: datetime,
    end_time: datetime,
) -> dict[str, Any]:
    requests = sum(metrics["requests"])
    target_errors = sum(metrics["target5xx"])
    load_balancer_errors = sum(metrics["elb5xx"])
    errors = target_errors + load_balancer_errors
    allowed_errors = requests * (1 - config.availability_target_percent / 100)
    availability = 100 * (1 - errors / requests) if requests else None
    availability_consumed = 100 * errors / allowed_errors if allowed_errors else None

    latency_seconds = metrics["latencyp95"]
    latency_violations = sum(
        value * 1000 > config.latency_target_ms for value in latency_seconds
    )
    latency_periods = len(latency_seconds)
    allowed_latency_violations = latency_periods * (
        1 - config.latency_compliance_target_percent / 100
    )
    latency_compliance = (
        100 * (latency_periods - latency_violations) / latency_periods
        if latency_periods
        else None
    )
    latency_consumed = (
        100 * latency_violations / allowed_latency_violations
        if allowed_latency_violations
        else None
    )

    gates = {
        "minimum_traffic": requests >= config.minimum_requests,
        "availability_budget_remaining": requests > 0 and errors <= allowed_errors,
        "latency_observations_present": latency_periods > 0,
        "latency_budget_remaining": (
            latency_periods > 0 and latency_violations <= allowed_latency_violations
        ),
    }
    return {
        "schema_version": 1,
        "generated_at": end_time.isoformat(),
        "window": {
            "start": start_time.isoformat(),
            "end": end_time.isoformat(),
            "hours": config.window_hours,
            "period_seconds": config.period_seconds,
        },
        "objectives": {
            "availability_target_percent": config.availability_target_percent,
            "p95_latency_target_ms": config.latency_target_ms,
            "latency_compliance_target_percent": (
                config.latency_compliance_target_percent
            ),
            "minimum_requests": config.minimum_requests,
        },
        "measurements": {
            "request_count": requests,
            "target_5xx_count": target_errors,
            "load_balancer_5xx_count": load_balancer_errors,
            "availability_percent": availability,
            "p95_latency_observed_periods": latency_periods,
            "p95_latency_violating_periods": latency_violations,
            "latency_compliance_percent": latency_compliance,
        },
        "error_budget": {
            "availability_allowed_errors": allowed_errors,
            "availability_consumed_percent": availability_consumed,
            "latency_allowed_violating_periods": allowed_latency_violations,
            "latency_consumed_percent": latency_consumed,
        },
        "gates": gates,
        "passed": all(gates.values()),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True)
    parser.add_argument("--load-balancer-suffix", required=True)
    parser.add_argument("--target-group-suffix", required=True)
    parser.add_argument("--window-hours", required=True, type=int)
    parser.add_argument("--period-seconds", default=300, type=int)
    parser.add_argument("--availability-target-percent", required=True, type=float)
    parser.add_argument("--latency-target-ms", required=True, type=float)
    parser.add_argument(
        "--latency-compliance-target-percent", required=True, type=float
    )
    parser.add_argument("--minimum-requests", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config = SLOConfig(
        region=args.region,
        load_balancer_suffix=args.load_balancer_suffix,
        target_group_suffix=args.target_group_suffix,
        window_hours=args.window_hours,
        period_seconds=args.period_seconds,
        availability_target_percent=args.availability_target_percent,
        latency_target_ms=args.latency_target_ms,
        latency_compliance_target_percent=args.latency_compliance_target_percent,
        minimum_requests=args.minimum_requests,
    )
    config.validate()
    end_time = datetime.now(timezone.utc).replace(microsecond=0)
    start_time = end_time - timedelta(hours=config.window_hours)
    cloudwatch = boto3.client("cloudwatch", region_name=config.region)
    report = evaluate_budget(
        config,
        collect_metrics(cloudwatch, config, start_time, end_time),
        start_time,
        end_time,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    availability = report["measurements"]["availability_percent"]
    availability_text = "n/a" if availability is None else f"{availability:.5f}%"
    print(
        f"SLO gate passed={report['passed']} requests={report['measurements']['request_count']:.0f} "
        f"availability={availability_text} latency_compliance="
        f"{report['measurements']['latency_compliance_percent']}"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
