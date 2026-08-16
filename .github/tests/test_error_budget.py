import sys
from datetime import datetime, timezone
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import pytest

SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "check_error_budget.py"
SPEC = spec_from_file_location("check_error_budget", SCRIPT_PATH)
assert SPEC and SPEC.loader
error_budget = module_from_spec(SPEC)
sys.modules[SPEC.name] = error_budget
SPEC.loader.exec_module(error_budget)


def config(**overrides):
    values = {
        "region": "ap-southeast-2",
        "load_balancer_suffix": "app/cloud-native-llmops/abc123",
        "target_group_suffix": "targetgroup/cloud-native-llmops/def456",
        "window_hours": 168,
        "period_seconds": 300,
        "availability_target_percent": 99.9,
        "latency_target_ms": 3000,
        "latency_compliance_target_percent": 99,
        "minimum_requests": 100,
    }
    values.update(overrides)
    return error_budget.SLOConfig(**values)


def window():
    end = datetime(2026, 8, 16, tzinfo=timezone.utc)
    return end.replace(day=9), end


def test_metric_queries_scope_each_metric_to_the_correct_dimensions():
    queries = {item["Id"]: item for item in error_budget.metric_queries(config())}

    assert set(queries) == {"requests", "target5xx", "elb5xx", "latencyp95"}
    assert queries["latencyp95"]["MetricStat"]["Stat"] == "p95"
    assert len(queries["requests"]["MetricStat"]["Metric"]["Dimensions"]) == 2
    assert len(queries["elb5xx"]["MetricStat"]["Metric"]["Dimensions"]) == 1


def test_collect_metrics_follows_cloudwatch_pagination():
    class CloudWatch:
        def __init__(self):
            self.requests = []

        def get_metric_data(self, **kwargs):
            self.requests.append(kwargs)
            if "NextToken" not in kwargs:
                return {
                    "MetricDataResults": [
                        {"Id": "requests", "Values": [50], "StatusCode": "Complete"}
                    ],
                    "NextToken": "next-page",
                }
            return {
                "MetricDataResults": [
                    {"Id": "requests", "Values": [75], "StatusCode": "Complete"}
                ]
            }

    client = CloudWatch()
    start, end = window()
    metrics = error_budget.collect_metrics(client, config(), start, end)

    assert metrics["requests"] == [50, 75]
    assert client.requests[1]["NextToken"] == "next-page"


def test_collect_metrics_rejects_partial_cloudwatch_data():
    class CloudWatch:
        def get_metric_data(self, **_):
            return {
                "MetricDataResults": [
                    {
                        "Id": "requests",
                        "Values": [100],
                        "StatusCode": "PartialData",
                    }
                ]
            }

    start, end = window()
    with pytest.raises(RuntimeError, match="was not complete"):
        error_budget.collect_metrics(CloudWatch(), config(), start, end)


def test_healthy_service_has_remaining_availability_and_latency_budgets():
    start, end = window()
    report = error_budget.evaluate_budget(
        config(),
        {
            "requests": [100_000],
            "target5xx": [20],
            "elb5xx": [5],
            "latencyp95": [0.8] * 999 + [2.9],
        },
        start,
        end,
    )

    assert report["passed"] is True
    assert report["measurements"]["availability_percent"] == pytest.approx(99.975)
    assert report["error_budget"]["availability_consumed_percent"] == pytest.approx(25)
    assert report["measurements"]["latency_compliance_percent"] == 100


@pytest.mark.parametrize(
    ("metrics", "failed_gate"),
    [
        (
            {
                "requests": [50],
                "target5xx": [],
                "elb5xx": [],
                "latencyp95": [0.5],
            },
            "minimum_traffic",
        ),
        (
            {
                "requests": [100_000],
                "target5xx": [101],
                "elb5xx": [],
                "latencyp95": [0.5] * 100,
            },
            "availability_budget_remaining",
        ),
        (
            {
                "requests": [100_000],
                "target5xx": [],
                "elb5xx": [],
                "latencyp95": [0.5] * 98 + [3.1, 4.0],
            },
            "latency_budget_remaining",
        ),
        (
            {
                "requests": [100_000],
                "target5xx": [],
                "elb5xx": [],
                "latencyp95": [],
            },
            "latency_observations_present",
        ),
    ],
)
def test_budget_gate_fails_closed(metrics, failed_gate):
    start, end = window()
    report = error_budget.evaluate_budget(config(), metrics, start, end)

    assert report["passed"] is False
    assert report["gates"][failed_gate] is False
    assert "prompt" not in str(report).lower()


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"window_hours": 0}, "window_hours"),
        ({"period_seconds": 61}, "period_seconds"),
        ({"availability_target_percent": 100}, "availability_target_percent"),
        ({"minimum_requests": 0}, "minimum_requests"),
        ({"load_balancer_suffix": "bad"}, "load_balancer_suffix"),
    ],
)
def test_invalid_slo_configuration_is_rejected(overrides, message):
    with pytest.raises(ValueError, match=message):
        config(**overrides).validate()
