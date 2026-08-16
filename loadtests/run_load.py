from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import sys
import time
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlparse

import httpx

SAFE_PROMPT = "Reply with exactly: load-test-ok"


@dataclass(frozen=True)
class LoadConfig:
    base_url: str
    api_key: str
    duration_seconds: float
    requests_per_second: float
    concurrency: int
    request_timeout_seconds: float
    max_error_rate: float
    max_p95_latency_ms: float
    min_throughput_ratio: float


@dataclass(frozen=True)
class RequestResult:
    latency_ms: float
    status_code: int | None
    success: bool
    error_type: str | None = None


def percentile(values: Sequence[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, math.ceil(quantile * len(ordered)) - 1)
    return round(ordered[index], 2)


def build_report(
    config: LoadConfig,
    results: Sequence[RequestResult],
    *,
    started_at: datetime,
    elapsed_seconds: float,
) -> dict[str, object]:
    total = len(results)
    succeeded = sum(result.success for result in results)
    failed = total - succeeded
    planned_requests = math.floor(
        config.duration_seconds * config.requests_per_second
    )
    error_rate = failed / total if total else 1.0
    achieved_rps = total / elapsed_seconds if elapsed_seconds > 0 else 0.0
    latencies = [result.latency_ms for result in results]
    status_counts = Counter(
        str(result.status_code) if result.status_code is not None else "transport_error"
        for result in results
    )
    error_counts = Counter(
        result.error_type for result in results if result.error_type is not None
    )
    checks = {
        "error_rate": error_rate <= config.max_error_rate,
        "p95_latency": percentile(latencies, 0.95) <= config.max_p95_latency_ms,
        "throughput": achieved_rps
        >= config.requests_per_second * config.min_throughput_ratio,
        "request_count": total > 0 and total == planned_requests,
    }

    return {
        "schema_version": 1,
        "started_at": started_at.astimezone(UTC).isoformat(),
        "target": {
            "origin": config.base_url.rstrip("/"),
            "duration_seconds": config.duration_seconds,
            "requests_per_second": config.requests_per_second,
            "concurrency": config.concurrency,
            "planned_requests": planned_requests,
        },
        "results": {
            "elapsed_seconds": round(elapsed_seconds, 3),
            "requests": total,
            "succeeded": succeeded,
            "failed": failed,
            "error_rate": round(error_rate, 6),
            "achieved_requests_per_second": round(achieved_rps, 3),
            "latency_ms": {
                "p50": percentile(latencies, 0.50),
                "p95": percentile(latencies, 0.95),
                "p99": percentile(latencies, 0.99),
            },
            "status_counts": dict(sorted(status_counts.items())),
            "error_counts": dict(sorted(error_counts.items())),
        },
        "thresholds": {
            "max_error_rate": config.max_error_rate,
            "max_p95_latency_ms": config.max_p95_latency_ms,
            "min_throughput_ratio": config.min_throughput_ratio,
        },
        "gate": {"passed": all(checks.values()), "checks": checks},
    }


async def _request_once(
    client: httpx.AsyncClient,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    started = time.perf_counter()
    status_code: int | None = None
    try:
        async with semaphore:
            response = await client.post("/v1/generate", json={"prompt": SAFE_PROMPT})
        status_code = response.status_code
        valid_body = False
        if 200 <= status_code < 300:
            try:
                body = response.json()
                valid_body = (
                    isinstance(body, dict)
                    and isinstance(body.get("output"), str)
                    and isinstance(body.get("model"), str)
                    and isinstance(body.get("latency_ms"), int)
                )
            except (TypeError, ValueError):
                valid_body = False
        if not 200 <= status_code < 300:
            error_type = f"http_{status_code}"
        elif not valid_body:
            error_type = "invalid_response"
        else:
            error_type = None
        return RequestResult(
            latency_ms=(time.perf_counter() - started) * 1000,
            status_code=status_code,
            success=error_type is None,
            error_type=error_type,
        )
    except httpx.TimeoutException:
        error_type = "timeout"
    except httpx.HTTPError:
        error_type = "transport_error"

    return RequestResult(
        latency_ms=(time.perf_counter() - started) * 1000,
        status_code=status_code,
        success=False,
        error_type=error_type,
    )


async def run_load(
    config: LoadConfig,
    *,
    transport: httpx.AsyncBaseTransport | None = None,
) -> dict[str, object]:
    started_at = datetime.now(UTC)
    started = time.perf_counter()
    request_count = max(1, math.floor(config.duration_seconds * config.requests_per_second))
    semaphore = asyncio.Semaphore(config.concurrency)
    timeout = httpx.Timeout(config.request_timeout_seconds)
    headers = {"X-API-Key": config.api_key, "User-Agent": "llmops-staging-load-gate/1"}

    async with httpx.AsyncClient(
        base_url=config.base_url.rstrip("/"),
        headers=headers,
        timeout=timeout,
        transport=transport,
        follow_redirects=False,
        trust_env=False,
    ) as client:
        queue: asyncio.Queue[int | None] = asyncio.Queue(
            maxsize=max(1, config.concurrency * 2)
        )
        results: list[RequestResult] = []

        async def worker() -> None:
            while True:
                sequence = await queue.get()
                try:
                    if sequence is None:
                        return
                    results.append(await _request_once(client, semaphore))
                finally:
                    queue.task_done()

        workers = [asyncio.create_task(worker()) for _ in range(config.concurrency)]
        for sequence in range(request_count):
            due_at = started + sequence / config.requests_per_second
            delay = due_at - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)
            await queue.put(sequence)
        await queue.join()
        for _ in workers:
            await queue.put(None)
        await asyncio.gather(*workers)

    elapsed = time.perf_counter() - started
    return build_report(
        config,
        results,
        started_at=started_at,
        elapsed_seconds=elapsed,
    )


def _bounded_number(name: str, value: float, minimum: float, maximum: float) -> float:
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def parse_args(argv: Sequence[str] | None = None) -> tuple[LoadConfig, Path]:
    parser = argparse.ArgumentParser(description="Run the staging inference load gate.")
    parser.add_argument("--url", default=os.getenv("LOAD_TEST_URL"))
    parser.add_argument("--duration-seconds", type=float, default=120)
    parser.add_argument("--requests-per-second", type=float, default=2)
    parser.add_argument("--concurrency", type=int, default=10)
    parser.add_argument("--request-timeout-seconds", type=float, default=30)
    parser.add_argument("--max-error-rate", type=float, default=0.01)
    parser.add_argument("--max-p95-latency-ms", type=float, default=3000)
    parser.add_argument("--min-throughput-ratio", type=float, default=0.90)
    parser.add_argument("--output", type=Path, default=Path("load-test-report.json"))
    args = parser.parse_args(argv)

    if not args.url:
        parser.error("--url or LOAD_TEST_URL is required")
    parsed_url = urlparse(args.url)
    if (
        parsed_url.scheme != "https"
        or not parsed_url.hostname
        or parsed_url.username is not None
        or parsed_url.password is not None
        or parsed_url.path not in ("", "/")
        or parsed_url.query
        or parsed_url.fragment
    ):
        parser.error("load-test URL must be an HTTPS origin without a path, query, or fragment")
    api_key = os.getenv("API_AUTH_TOKEN", "")
    if not 32 <= len(api_key) <= 128:
        parser.error("API_AUTH_TOKEN must contain 32-128 characters")

    try:
        config = LoadConfig(
            base_url=args.url.rstrip("/"),
            api_key=api_key,
            duration_seconds=_bounded_number("duration", args.duration_seconds, 10, 900),
            requests_per_second=_bounded_number(
                "requests per second", args.requests_per_second, 0.1, 100
            ),
            concurrency=int(
                _bounded_number("concurrency", args.concurrency, 1, 200)
            ),
            request_timeout_seconds=_bounded_number(
                "request timeout", args.request_timeout_seconds, 1, 60
            ),
            max_error_rate=_bounded_number(
                "maximum error rate", args.max_error_rate, 0, 0.20
            ),
            max_p95_latency_ms=_bounded_number(
                "maximum P95 latency", args.max_p95_latency_ms, 100, 30000
            ),
            min_throughput_ratio=_bounded_number(
                "minimum throughput ratio", args.min_throughput_ratio, 0.50, 1
            ),
        )
        if config.duration_seconds * config.requests_per_second < 10:
            raise ValueError("duration and request rate must schedule at least 10 requests")
    except ValueError as exc:
        parser.error(str(exc))
    return config, args.output


def main(argv: Sequence[str] | None = None) -> int:
    config, output_path = parse_args(argv)
    report = asyncio.run(run_load(config))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    results = report["results"]
    gate = report["gate"]
    print(
        "Performance gate "
        f"{'PASSED' if gate['passed'] else 'FAILED'}: "
        f"requests={results['requests']} "
        f"errors={results['error_rate']:.2%} "
        f"p95={results['latency_ms']['p95']:.2f}ms "
        f"rps={results['achieved_requests_per_second']:.3f}"
    )
    return 0 if gate["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
