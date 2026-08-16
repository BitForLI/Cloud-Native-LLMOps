import asyncio
import json
from datetime import UTC, datetime

import httpx
import pytest

from loadtests.run_load import (
    LoadConfig,
    RequestResult,
    _request_once,
    build_report,
    parse_args,
    percentile,
    run_load,
)


def config(**overrides):
    values = {
        "base_url": "https://staging.example.com",
        "api_key": "a" * 32,
        "duration_seconds": 10,
        "requests_per_second": 2,
        "concurrency": 4,
        "request_timeout_seconds": 5,
        "max_error_rate": 0.01,
        "max_p95_latency_ms": 3000,
        "min_throughput_ratio": 0.90,
    }
    values.update(overrides)
    return LoadConfig(**values)


def test_percentile_uses_nearest_rank_and_empty_default():
    assert percentile([], 0.95) == 0
    assert percentile([1, 2, 3, 4, 100], 0.50) == 3
    assert percentile([1, 2, 3, 4, 100], 0.95) == 100


def test_report_enforces_all_capacity_thresholds_without_sensitive_payloads():
    report = build_report(
        config(duration_seconds=1.5),
        [
            RequestResult(100, 200, True),
            RequestResult(200, 200, True),
            RequestResult(4000, 503, False, "http_503"),
        ],
        started_at=datetime(2026, 1, 1, tzinfo=UTC),
        elapsed_seconds=2,
    )

    assert report["gate"] == {
        "passed": False,
        "checks": {
            "error_rate": False,
            "p95_latency": False,
            "throughput": False,
            "request_count": True,
        },
    }
    serialized = json.dumps(report)
    assert "Reply with exactly" not in serialized
    assert "X-API-Key" not in serialized
    assert "a" * 32 not in serialized
    assert report["results"]["error_counts"] == {"http_503": 1}


def test_request_requires_valid_inference_response_shape():
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["X-API-Key"] == "a" * 32
        assert json.loads(request.content) == {"prompt": "Reply with exactly: load-test-ok"}
        return httpx.Response(200, json={"output": "ok", "model": "test", "latency_ms": 12})

    async def execute():
        transport = httpx.MockTransport(handler)
        async with httpx.AsyncClient(
            base_url="https://staging.example.com",
            headers={"X-API-Key": "a" * 32},
            transport=transport,
        ) as client:
            return await _request_once(client, asyncio.Semaphore(1))

    result = asyncio.run(execute())
    assert result.success
    assert result.status_code == 200
    assert result.error_type is None


def test_request_classifies_invalid_body_and_http_failures():
    responses = iter(
        [
            httpx.Response(200, json={"output": "missing metadata"}),
            httpx.Response(429, json={"error": {"code": "rate_limited"}}),
        ]
    )

    async def handler(_: httpx.Request) -> httpx.Response:
        return next(responses)

    async def execute():
        async with httpx.AsyncClient(
            base_url="https://staging.example.com",
            transport=httpx.MockTransport(handler),
        ) as client:
            semaphore = asyncio.Semaphore(1)
            return (
                await _request_once(client, semaphore),
                await _request_once(client, semaphore),
            )

    invalid, throttled = asyncio.run(execute())
    assert invalid.error_type == "invalid_response"
    assert throttled.error_type == "http_429"


def test_scheduler_completes_exact_planned_request_count():
    async def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={"output": "load-test-ok", "model": "test", "latency_ms": 1},
        )

    report = asyncio.run(
        run_load(
            config(
                duration_seconds=0.01,
                requests_per_second=1000,
                concurrency=2,
                min_throughput_ratio=0,
            ),
            transport=httpx.MockTransport(handler),
        )
    )
    assert report["target"]["planned_requests"] == 10
    assert report["results"]["requests"] == 10
    assert report["results"]["failed"] == 0


def test_cli_rejects_unsafe_origin_and_accepts_bounded_values(monkeypatch, tmp_path):
    monkeypatch.setenv("API_AUTH_TOKEN", "x" * 32)
    report_path = tmp_path / "report.json"
    parsed, output = parse_args(
        [
            "--url",
            "https://staging.example.com",
            "--duration-seconds",
            "30",
            "--requests-per-second",
            "3",
            "--concurrency",
            "8",
            "--output",
            str(report_path),
        ]
    )
    assert parsed.duration_seconds == 30
    assert parsed.requests_per_second == 3
    assert parsed.concurrency == 8
    assert output == report_path

    for unsafe_url in (
        "http://staging.example.com",
        "https://staging.example.com/v1/generate",
        "https://staging.example.com?token=secret",
        "https://user:password@staging.example.com",
    ):
        with pytest.raises(SystemExit):
            parse_args(["--url", unsafe_url])

    with pytest.raises(SystemExit):
        parse_args(["--url", "https://staging.example.com", "--requests-per-second", "101"])

    with pytest.raises(SystemExit):
        parse_args(
            [
                "--url",
                "https://staging.example.com",
                "--duration-seconds",
                "10",
                "--requests-per-second",
                "0.1",
            ]
        )
