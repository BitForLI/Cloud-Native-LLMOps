from math import ceil

from evals.config import EvalConfig
from evals.models import EvalResult, EvalScores


class QualityGateError(AssertionError):
    def __init__(self, failures: list[str]) -> None:
        self.failures = tuple(failures)
        super().__init__("; ".join(failures))


def exact_match_score(results: list[EvalResult]) -> float:
    _require_results(results)
    passed = sum(
        result.error_type is None
        and result.actual_output.strip() == result.expected_output.strip()
        for result in results
    )
    return round(passed / len(results), 6)


def tool_success_score(results: list[EvalResult]) -> float | None:
    applicable = [result for result in results if result.expected_tool is not None]
    if not applicable:
        return None
    passed = sum(result.tool_success is True for result in applicable)
    return round(passed / len(applicable), 6)


def p95_latency(results: list[EvalResult]) -> float:
    _require_results(results)
    values = sorted(result.latency_ms for result in results)
    index = max(0, ceil(0.95 * len(values)) - 1)
    return round(values[index], 2)


def total_estimated_cost(results: list[EvalResult]) -> float | None:
    observed = [
        result.estimated_cost_usd
        for result in results
        if result.estimated_cost_usd is not None
    ]
    if not observed:
        return None
    return round(sum(observed), 8)


def calculate_scores(results: list[EvalResult]) -> EvalScores:
    return EvalScores(
        accuracy=exact_match_score(results),
        tool_success_rate=tool_success_score(results),
        p95_latency_ms=p95_latency(results),
        estimated_cost_usd=total_estimated_cost(results),
    )


def quality_gate(scores: EvalScores, config: EvalConfig) -> None:
    failures: list[str] = []
    if scores.accuracy < config.accuracy_threshold:
        failures.append(
            f"accuracy {scores.accuracy:.2%} is below "
            f"{config.accuracy_threshold:.2%}"
        )

    if scores.tool_success_rate is None:
        if config.require_tool_evaluation:
            failures.append("tool success score is required but no tool cases ran")
    elif scores.tool_success_rate < config.tool_success_threshold:
        failures.append(
            f"tool success {scores.tool_success_rate:.2%} is below "
            f"{config.tool_success_threshold:.2%}"
        )

    if scores.p95_latency_ms > config.p95_latency_threshold_ms:
        failures.append(
            f"P95 latency {scores.p95_latency_ms:.2f}ms exceeds "
            f"{config.p95_latency_threshold_ms:.2f}ms"
        )

    if (
        scores.estimated_cost_usd is not None
        and scores.estimated_cost_usd > config.max_estimated_cost_usd
    ):
        failures.append(
            f"estimated cost ${scores.estimated_cost_usd:.6f} exceeds "
            f"${config.max_estimated_cost_usd:.6f}"
        )

    if failures:
        raise QualityGateError(failures)


def _require_results(results: list[EvalResult]) -> None:
    if not results:
        raise ValueError("At least one evaluation result is required.")

