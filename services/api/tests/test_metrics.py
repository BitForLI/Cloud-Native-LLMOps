from concurrent.futures import ThreadPoolExecutor

import pytest
from app.main import app
from app.metrics import Metrics, get_metrics
from fastapi.testclient import TestClient

client = TestClient(app)


def test_metrics_snapshot_calculates_rates_percentiles_and_totals():
    metrics = Metrics()
    metrics.record_request(200)
    metrics.record_request(404)
    metrics.record_request(500)
    for latency in (10, 20, 30, 40):
        metrics.record_llm_latency(latency)
    metrics.record_model_error()
    metrics.record_token_usage(100, 40)
    metrics.record_token_usage(10, 5)
    metrics.record_estimated_cost(0.000075)
    metrics.record_estimated_cost(0.000025)

    snapshot = metrics.snapshot()

    assert snapshot.request_count == 3
    assert snapshot.error_count == 2
    assert snapshot.error_rate == 0.666667
    assert snapshot.llm_request_count == 4
    assert snapshot.model_error_count == 1
    assert snapshot.model_error_rate == 0.25
    assert snapshot.llm_latency_p50_ms == 20
    assert snapshot.llm_latency_p95_ms == 40
    assert snapshot.input_tokens_total == 110
    assert snapshot.output_tokens_total == 45
    assert snapshot.estimated_llm_cost_usd == 0.0001


def test_latency_history_is_bounded_without_losing_request_count():
    metrics = Metrics(max_latency_samples=2)

    for latency in (10, 20, 30):
        metrics.record_llm_latency(latency)

    snapshot = metrics.snapshot()
    assert snapshot.llm_request_count == 3
    assert snapshot.llm_latency_p50_ms == 20
    assert snapshot.llm_latency_p95_ms == 30


def test_metrics_updates_are_thread_safe():
    metrics = Metrics()

    def record_batch():
        for _ in range(250):
            metrics.record_request(200)
            metrics.record_llm_latency(5)
            metrics.record_token_usage(2, 1)
            metrics.record_estimated_cost(0.000001)

    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(lambda _: record_batch(), range(8)))

    snapshot = metrics.snapshot()
    assert snapshot.request_count == 2_000
    assert snapshot.llm_request_count == 2_000
    assert snapshot.input_tokens_total == 4_000
    assert snapshot.output_tokens_total == 2_000
    assert snapshot.estimated_llm_cost_usd == 0.002


@pytest.mark.parametrize(
    ("method", "args"),
    [
        ("record_request", (99,)),
        ("record_llm_latency", (-1,)),
        ("record_token_usage", (-1, 0)),
        ("record_estimated_cost", (-0.01,)),
    ],
)
def test_metrics_reject_invalid_values(method, args):
    metrics = Metrics()

    with pytest.raises(ValueError):
        getattr(metrics, method)(*args)


def test_generate_records_llm_metrics_and_metrics_endpoint_exposes_snapshot():
    metrics = get_metrics()

    generate_response = client.post("/v1/generate", json={"prompt": "hello"})
    metrics_response = client.get("/metrics")

    assert generate_response.status_code == 200
    assert generate_response.json()["estimated_cost"] == 0.0
    body = metrics_response.json()
    assert body["request_count"] == 1
    assert body["llm_request_count"] == 1
    assert body["model_error_count"] == 0
    assert body["estimated_llm_cost_usd"] == 0.0
    assert metrics.snapshot().request_count == 2
