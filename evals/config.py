import os
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class EvalConfig:
    accuracy_threshold: float = 0.90
    tool_success_threshold: float = 0.95
    p95_latency_threshold_ms: float = 3_000.0
    max_estimated_cost_usd: float = 0.10
    require_tool_evaluation: bool = False

    def __post_init__(self) -> None:
        for name, value in (
            ("accuracy_threshold", self.accuracy_threshold),
            ("tool_success_threshold", self.tool_success_threshold),
        ):
            if not 0 <= value <= 1:
                raise ValueError(f"{name} must be between 0 and 1")
        if self.p95_latency_threshold_ms <= 0:
            raise ValueError("p95_latency_threshold_ms must be positive")
        if self.max_estimated_cost_usd < 0:
            raise ValueError("max_estimated_cost_usd must not be negative")

    @classmethod
    def from_env(cls) -> "EvalConfig":
        return cls(
            accuracy_threshold=_float_env("EVAL_ACCURACY_THRESHOLD", 0.90),
            tool_success_threshold=_float_env(
                "EVAL_TOOL_SUCCESS_THRESHOLD", 0.95
            ),
            p95_latency_threshold_ms=_float_env(
                "EVAL_P95_LATENCY_THRESHOLD_MS", 3_000.0
            ),
            max_estimated_cost_usd=_float_env(
                "EVAL_MAX_ESTIMATED_COST_USD", 0.10
            ),
            require_tool_evaluation=_bool_env(
                "EVAL_REQUIRE_TOOL_EVALUATION", False
            ),
        )


def _float_env(name: str, default: float) -> float:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    try:
        return float(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} must be numeric") from exc


def _bool_env(name: str, default: bool) -> bool:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    normalized = raw_value.strip().lower()
    if normalized in {"1", "true", "yes"}:
        return True
    if normalized in {"0", "false", "no"}:
        return False
    raise ValueError(f"{name} must be true or false")

