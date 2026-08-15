"""Run deterministic pre-deployment evaluation quality gates."""

import json
import time
from collections.abc import Callable
from pathlib import Path

from evals.config import EvalConfig
from evals.metrics import QualityGateError, calculate_scores, quality_gate
from evals.models import (
    DatasetValidationError,
    EvalCase,
    EvalReport,
    EvalResult,
    Prediction,
)

Predictor = Callable[[str], Prediction]
DEFAULT_DATASET = Path(__file__).with_name("dataset.json")


def predict(prompt: str) -> Prediction:
    """Deterministic provider used by CI until an environment adapter is selected."""

    return Prediction(output=f"Received: {prompt.strip()}", estimated_cost_usd=0.0)


def load_dataset(path: Path = DEFAULT_DATASET) -> list[EvalCase]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DatasetValidationError(f"Cannot load evaluation dataset: {path}") from exc

    if not isinstance(payload, list) or not payload:
        raise DatasetValidationError("Evaluation dataset must be a non-empty list.")

    cases = [EvalCase.from_dict(value) for value in payload]
    case_ids = [case.case_id for case in cases]
    if len(case_ids) != len(set(case_ids)):
        raise DatasetValidationError("Evaluation case IDs must be unique.")
    return cases


def evaluate_case(case: EvalCase, predictor: Predictor) -> EvalResult:
    started = time.perf_counter()
    try:
        prediction = predictor(case.prompt)
    # Evaluation must convert provider failures into failed cases so the gate can
    # report aggregate regressions instead of aborting on the first model error.
    except Exception as exc:  # noqa: BLE001
        return EvalResult(
            case_id=case.case_id,
            expected_output=case.expected_output,
            actual_output="",
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            expected_tool=case.expected_tool,
            actual_tool=None,
            tool_success=False if case.expected_tool else None,
            input_tokens=None,
            output_tokens=None,
            estimated_cost_usd=None,
            error_type=type(exc).__name__,
        )

    return EvalResult(
        case_id=case.case_id,
        expected_output=case.expected_output,
        actual_output=prediction.output,
        latency_ms=round((time.perf_counter() - started) * 1000, 2),
        expected_tool=case.expected_tool,
        actual_tool=prediction.tool_name,
        tool_success=(
            prediction.tool_name == case.expected_tool if case.expected_tool else None
        ),
        input_tokens=prediction.input_tokens,
        output_tokens=prediction.output_tokens,
        estimated_cost_usd=prediction.estimated_cost_usd,
    )


def run_evaluation(
    cases: list[EvalCase],
    predictor: Predictor = predict,
    config: EvalConfig | None = None,
) -> tuple[list[EvalResult], EvalReport]:
    active_config = config or EvalConfig.from_env()
    results = [evaluate_case(case, predictor) for case in cases]
    scores = calculate_scores(results)
    failures: tuple[str, ...] = ()
    status = "PASS"
    try:
        quality_gate(scores, active_config)
    except QualityGateError as exc:
        failures = exc.failures
        status = "FAIL"

    report = EvalReport(
        case_count=len(results),
        accuracy=scores.accuracy,
        tool_success_rate=scores.tool_success_rate,
        p95_latency_ms=scores.p95_latency_ms,
        estimated_cost_usd=scores.estimated_cost_usd,
        overall_status=status,
        failures=failures,
    )
    return results, report


def run_cli(dataset_path: Path = DEFAULT_DATASET) -> int:
    cases = load_dataset(dataset_path)
    _, report = run_evaluation(cases)
    print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    return 0 if report.overall_status == "PASS" else 1


def main() -> None:
    raise SystemExit(run_cli())


if __name__ == "__main__":
    main()
