import time
from typing import Annotated

from fastapi import Depends, FastAPI, Request
from pydantic import BaseModel, Field

from app.config import Settings, get_settings
from app.logging import configure_logging
from app.metrics import Metrics, MetricsSnapshot, get_metrics
from app.middleware import request_context_middleware
from app.providers.base import LLMProvider
from app.providers.factory import get_provider

configure_logging(get_settings().log_level)
app = FastAPI(title="LLMOps Inference API", version="0.1.0")
app.middleware("http")(request_context_middleware)


class GenerateRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=8000)


class GenerateResponse(BaseModel):
    output: str
    model: str
    latency_ms: int
    input_tokens: int | None = None
    output_tokens: int | None = None
    estimated_cost: float | None = None


@app.get("/health")
def health(settings: Annotated[Settings, Depends(get_settings)]) -> dict[str, str]:
    return {"status": "ok", "environment": settings.app_env}


@app.get("/ready")
def ready() -> dict[str, str]:
    # Extend with Bedrock, DynamoDB, and S3 dependency checks during AWS integration.
    return {"status": "ready"}


@app.get("/metrics")
def metrics_snapshot(
    metrics: Annotated[Metrics, Depends(get_metrics)],
) -> MetricsSnapshot:
    return metrics.snapshot()


@app.post("/v1/generate", response_model=GenerateResponse)
def generate(
    payload: GenerateRequest,
    request: Request,
    provider: Annotated[LLMProvider, Depends(get_provider)],
    metrics: Annotated[Metrics, Depends(get_metrics)],
) -> GenerateResponse:
    request.state.model_id = provider.model_id
    started = time.perf_counter()
    try:
        result = provider.generate(payload.prompt)
    except Exception:
        metrics.record_model_error()
        raise
    finally:
        llm_latency_ms = (time.perf_counter() - started) * 1000
        metrics.record_llm_latency(llm_latency_ms)

    if result.input_tokens is not None and result.output_tokens is not None:
        metrics.record_token_usage(result.input_tokens, result.output_tokens)
    if result.estimated_cost is not None:
        metrics.record_estimated_cost(result.estimated_cost)

    return GenerateResponse(
        output=result.output,
        model=result.model_id,
        latency_ms=round(llm_latency_ms),
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        estimated_cost=result.estimated_cost,
    )
