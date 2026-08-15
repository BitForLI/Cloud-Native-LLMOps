from collections import deque
from dataclasses import asdict, dataclass
from decimal import Decimal
from math import ceil
from threading import Lock


@dataclass(frozen=True, slots=True)
class MetricsSnapshot:
    request_count: int
    error_count: int
    error_rate: float
    llm_request_count: int
    model_error_count: int
    model_error_rate: float
    llm_latency_p50_ms: float | None
    llm_latency_p95_ms: float | None
    input_tokens_total: int
    output_tokens_total: int
    estimated_llm_cost_usd: float

    def to_dict(self) -> dict[str, int | float | None]:
        return asdict(self)


class Metrics:
    """Thread-safe, process-local metrics store with bounded latency history."""

    def __init__(self, max_latency_samples: int = 10_000) -> None:
        if max_latency_samples < 1:
            raise ValueError("max_latency_samples must be positive")
        self._lock = Lock()
        self._max_latency_samples = max_latency_samples
        self.reset()

    def reset(self) -> None:
        with self._lock:
            self._request_count = 0
            self._error_count = 0
            self._llm_request_count = 0
            self._model_error_count = 0
            self._input_tokens_total = 0
            self._output_tokens_total = 0
            self._estimated_cost_total = Decimal(0)
            self._llm_latencies: deque[float] = deque(
                maxlen=self._max_latency_samples
            )

    def record_request(self, status_code: int) -> None:
        if not 100 <= status_code <= 599:
            raise ValueError("status_code must be between 100 and 599")
        with self._lock:
            self._request_count += 1
            if status_code >= 400:
                self._error_count += 1

    def record_llm_latency(self, latency_ms: float) -> None:
        if latency_ms < 0:
            raise ValueError("latency_ms must not be negative")
        with self._lock:
            self._llm_request_count += 1
            self._llm_latencies.append(float(latency_ms))

    def record_token_usage(self, input_tokens: int, output_tokens: int) -> None:
        if input_tokens < 0 or output_tokens < 0:
            raise ValueError("token counts must not be negative")
        with self._lock:
            self._input_tokens_total += input_tokens
            self._output_tokens_total += output_tokens

    def record_estimated_cost(self, cost_usd: float) -> None:
        if cost_usd < 0:
            raise ValueError("estimated cost must not be negative")
        with self._lock:
            self._estimated_cost_total += Decimal(str(cost_usd))

    def record_model_error(self) -> None:
        with self._lock:
            self._model_error_count += 1

    def snapshot(self) -> MetricsSnapshot:
        with self._lock:
            request_count = self._request_count
            error_count = self._error_count
            model_error_count = self._model_error_count
            llm_request_count = self._llm_request_count
            latencies = sorted(self._llm_latencies)
            input_tokens = self._input_tokens_total
            output_tokens = self._output_tokens_total
            estimated_cost = self._estimated_cost_total

        return MetricsSnapshot(
            request_count=request_count,
            error_count=error_count,
            error_rate=_ratio(error_count, request_count),
            llm_request_count=llm_request_count,
            model_error_count=model_error_count,
            model_error_rate=_ratio(model_error_count, llm_request_count),
            llm_latency_p50_ms=_percentile(latencies, 0.50),
            llm_latency_p95_ms=_percentile(latencies, 0.95),
            input_tokens_total=input_tokens,
            output_tokens_total=output_tokens,
            estimated_llm_cost_usd=float(estimated_cost),
        )


def _ratio(numerator: int, denominator: int) -> float:
    return round(numerator / denominator, 6) if denominator else 0.0


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    index = max(0, ceil(percentile * len(values)) - 1)
    return round(values[index], 2)


_metrics = Metrics()


def get_metrics() -> Metrics:
    return _metrics
