import io
import json

import pytest

from services.common.observability.emf import (
    build_inference_emf,
    configure_emf_logging,
    emit_inference_metrics,
)


def test_emf_contains_stable_dimensions_and_no_inference_content():
    payload = build_inference_emf(
        service="worker",
        environment="dev",
        model="model-1",
        latency_ms=125.25,
        model_error=False,
        input_tokens=10,
        output_tokens=4,
        estimated_cost_usd=0.001,
    )

    assert payload["LLMRequestCount"] == 1
    assert payload["ModelErrorCount"] == 0
    assert payload["EstimatedCostUSD"] == 0.001
    metadata = payload["_aws"]["CloudWatchMetrics"][0]
    assert metadata["Namespace"] == "CloudNativeLLMOps"
    assert metadata["Dimensions"] == [["Environment", "Service", "Model"]]
    assert "prompt" not in json.dumps(payload).lower()
    assert "output" not in payload


def test_emf_error_omits_unknown_usage_and_emits_raw_json():
    stream = io.StringIO()
    configure_emf_logging(stream)

    emit_inference_metrics(
        service="api",
        environment="staging",
        model="model-1",
        latency_ms=50,
        model_error=True,
    )

    payload = json.loads(stream.getvalue())
    assert payload["ModelErrorCount"] == 1
    assert "InputTokens" not in payload
    assert stream.getvalue().startswith("{")


@pytest.mark.parametrize("value", [-1, float("inf"), float("nan"), True])
def test_emf_rejects_invalid_numeric_values(value):
    with pytest.raises(ValueError, match="latency_ms"):
        build_inference_emf(
            service="worker",
            environment="dev",
            model="model",
            latency_ms=value,
            model_error=False,
        )
