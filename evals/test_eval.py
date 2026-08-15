import json
from dataclasses import replace

import pytest

from evals.config import EvalConfig
from evals.metrics import (
    QualityGateError,
    calculate_scores,
    exact_match_score,
    p95_latency,
    quality_gate,
    tool_success_score,
    total_estimated_cost,
)
from evals.models import (
    DatasetValidationError,
    EvalCase,
    EvalResult,
    EvalScores,
    Prediction,
)
from evals.run_eval import evaluate_case, load_dataset, run_cli, run_evaluation


def make_result(
    case_id="case",
    expected="expected",
    actual="expected",
    latency_ms=10.0,
    expected_tool=None,
    actual_tool=None,
    tool_success=None,
    estimated_cost=0.0,
    error_type=None,
):
    return EvalResult(
        case_id=case_id,
        expected_output=expected,
        actual_output=actual,
        latency_ms=latency_ms,
        expected_tool=expected_tool,
        actual_tool=actual_tool,
        tool_success=tool_success,
        input_tokens=10,
        output_tokens=5,
        estimated_cost_usd=estimated_cost,
        error_type=error_type,
    )


def test_dataset_loader_validates_and_rejects_duplicate_ids(tmp_path):
    dataset = tmp_path / "dataset.json"
    dataset.write_text(
        json.dumps(
            [
                {"id": "duplicate", "prompt": "one", "expected_output": "one"},
                {"id": "duplicate", "prompt": "two", "expected_output": "two"},
            ]
        ),
        encoding="utf-8",
    )

    with pytest.raises(DatasetValidationError, match="unique"):
        load_dataset(dataset)


@pytest.mark.parametrize(
    "payload",
    [
        [],
        [{"prompt": "missing id", "expected_output": "x"}],
        [{"id": "x", "prompt": "", "expected_output": "x"}],
        [{"id": "x", "prompt": "x", "expected_output": "x", "expected_tool": 1}],
    ],
)
def test_dataset_loader_rejects_invalid_cases(tmp_path, payload):
    dataset = tmp_path / "dataset.json"
    dataset.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(DatasetValidationError):
        load_dataset(dataset)


def test_scores_cover_accuracy_tools_latency_and_cost():
    results = [
        make_result(
            case_id="one",
            expected_tool="search",
            actual_tool="search",
            tool_success=True,
            latency_ms=10,
            estimated_cost=0.01,
        ),
        make_result(
            case_id="two",
            actual="wrong",
            expected_tool="lookup",
            actual_tool="other",
            tool_success=False,
            latency_ms=30,
            estimated_cost=0.02,
        ),
        make_result(case_id="three", latency_ms=20, estimated_cost=0.03),
    ]

    assert exact_match_score(results) == 0.666667
    assert tool_success_score(results) == 0.5
    assert p95_latency(results) == 30
    assert total_estimated_cost(results) == 0.06
    assert calculate_scores(results) == EvalScores(
        accuracy=0.666667,
        tool_success_rate=0.5,
        p95_latency_ms=30,
        estimated_cost_usd=0.06,
    )


def test_scores_treat_prediction_errors_as_incorrect():
    result = make_result(actual="expected", error_type="TimeoutError")

    assert exact_match_score([result]) == 0.0


def test_tool_score_and_cost_are_unknown_without_observations():
    result = make_result(estimated_cost=None)

    assert tool_success_score([result]) is None
    assert total_estimated_cost([result]) is None


def test_quality_gate_reports_every_failure():
    scores = EvalScores(
        accuracy=0.80,
        tool_success_rate=0.70,
        p95_latency_ms=4_000,
        estimated_cost_usd=0.20,
    )

    with pytest.raises(QualityGateError) as exc:
        quality_gate(scores, EvalConfig())

    assert len(exc.value.failures) == 4
    assert "accuracy" in exc.value.failures[0]
    assert "tool success" in exc.value.failures[1]
    assert "P95 latency" in exc.value.failures[2]
    assert "estimated cost" in exc.value.failures[3]


def test_quality_regression_from_92_to_81_percent_blocks_deployment():
    baseline = [
        make_result(case_id=str(index), actual="expected" if index < 92 else "wrong")
        for index in range(100)
    ]
    regression = [
        replace(result, actual_output="wrong" if index >= 81 else "expected")
        for index, result in enumerate(baseline)
    ]
    config = EvalConfig(accuracy_threshold=0.90)

    quality_gate(calculate_scores(baseline), config)
    with pytest.raises(QualityGateError, match="81.00%"):
        quality_gate(calculate_scores(regression), config)


def test_required_tool_evaluation_fails_when_dataset_has_no_tool_cases():
    scores = EvalScores(
        accuracy=1.0,
        tool_success_rate=None,
        p95_latency_ms=1,
        estimated_cost_usd=0.0,
    )

    with pytest.raises(QualityGateError, match="no tool cases"):
        quality_gate(scores, EvalConfig(require_tool_evaluation=True))


def test_evaluate_case_captures_predictor_error_without_leaking_message():
    case = EvalCase("failure", "prompt", "expected")

    def failing_predictor(prompt):
        raise TimeoutError("sensitive provider detail")

    result = evaluate_case(case, failing_predictor)

    assert result.actual_output == ""
    assert result.error_type == "TimeoutError"
    assert "sensitive provider detail" not in repr(result)


def test_run_evaluation_returns_pass_report_for_valid_prediction():
    cases = [EvalCase("one", "hello", "answer", expected_tool="search")]

    def predictor(prompt):
        return Prediction(
            output="answer",
            tool_name="search",
            input_tokens=10,
            output_tokens=4,
            estimated_cost_usd=0.001,
        )

    results, report = run_evaluation(cases, predictor, EvalConfig())

    assert results[0].tool_success is True
    assert report.overall_status == "PASS"
    assert report.accuracy == 1.0
    assert report.tool_success_rate == 1.0
    assert report.estimated_cost_usd == 0.001


def test_eval_config_reads_environment(monkeypatch):
    monkeypatch.setenv("EVAL_ACCURACY_THRESHOLD", "0.8")
    monkeypatch.setenv("EVAL_TOOL_SUCCESS_THRESHOLD", "0.85")
    monkeypatch.setenv("EVAL_P95_LATENCY_THRESHOLD_MS", "1500")
    monkeypatch.setenv("EVAL_MAX_ESTIMATED_COST_USD", "0.05")
    monkeypatch.setenv("EVAL_REQUIRE_TOOL_EVALUATION", "true")

    config = EvalConfig.from_env()

    assert config == EvalConfig(0.8, 0.85, 1500, 0.05, True)


def test_cli_prints_machine_readable_pass_report(capsys):
    exit_code = run_cli()

    report = json.loads(capsys.readouterr().out)
    assert exit_code == 0
    assert report["overall_status"] == "PASS"
    assert report["case_count"] == 10
    assert report["accuracy"] == 1.0
