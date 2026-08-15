import json
import logging
import math
import sys
import time
from typing import TextIO

EMF_NAMESPACE = "CloudNativeLLMOps"
logger = logging.getLogger("llmops.emf")


def configure_emf_logging(stream: TextIO | None = None) -> None:
    """Configure a raw JSON logger so CloudWatch can extract embedded metrics."""

    handler = logging.StreamHandler(stream or sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.handlers.clear()
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False


def emit_inference_metrics(
    *,
    service: str,
    environment: str,
    model: str,
    latency_ms: float,
    model_error: bool,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    estimated_cost_usd: float | None = None,
) -> None:
    logger.info(
        json.dumps(
            build_inference_emf(
                service=service,
                environment=environment,
                model=model,
                latency_ms=latency_ms,
                model_error=model_error,
                input_tokens=input_tokens,
                output_tokens=output_tokens,
                estimated_cost_usd=estimated_cost_usd,
            ),
            separators=(",", ":"),
        )
    )


def build_inference_emf(
    *,
    service: str,
    environment: str,
    model: str,
    latency_ms: float,
    model_error: bool,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    estimated_cost_usd: float | None = None,
) -> dict[str, object]:
    """Build one prompt-free CloudWatch Embedded Metric Format event."""

    if not all(value.strip() for value in (service, environment, model)):
        raise ValueError("metric dimensions must not be empty")
    _non_negative_finite("latency_ms", latency_ms)
    for name, value in (
        ("input_tokens", input_tokens),
        ("output_tokens", output_tokens),
        ("estimated_cost_usd", estimated_cost_usd),
    ):
        if value is not None:
            _non_negative_finite(name, value)

    values: dict[str, object] = {
        "Service": service,
        "Environment": environment,
        "Model": model,
        "LLMRequestCount": 1,
        "ModelErrorCount": int(model_error),
        "LLMLatencyMs": round(float(latency_ms), 3),
    }
    definitions: list[dict[str, str]] = [
        {"Name": "LLMRequestCount", "Unit": "Count"},
        {"Name": "ModelErrorCount", "Unit": "Count"},
        {"Name": "LLMLatencyMs", "Unit": "Milliseconds"},
    ]
    optional_metrics = (
        ("InputTokens", input_tokens, "Count"),
        ("OutputTokens", output_tokens, "Count"),
        ("EstimatedCostUSD", estimated_cost_usd, "None"),
    )
    for metric_name, value, unit in optional_metrics:
        if value is not None:
            values[metric_name] = value
            definitions.append({"Name": metric_name, "Unit": unit})

    values["_aws"] = {
        "Timestamp": int(time.time() * 1000),
        "CloudWatchMetrics": [
            {
                "Namespace": EMF_NAMESPACE,
                "Dimensions": [["Environment", "Service", "Model"]],
                "Metrics": definitions,
            }
        ],
    }
    return values


def _non_negative_finite(name: str, value: float) -> None:
    if isinstance(value, bool) or not math.isfinite(value) or value < 0:
        raise ValueError(f"{name} must be a non-negative finite number")
