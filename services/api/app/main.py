import time
from typing import Annotated

from fastapi import Depends, FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.config import Settings, get_settings
from app.logging import configure_logging
from app.metrics import Metrics, MetricsSnapshot, get_metrics
from app.middleware import request_context_middleware
from app.providers.base import LLMProvider, LLMProviderError
from app.providers.bedrock import BedrockResponseError
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


class ErrorDetail(BaseModel):
    code: str
    message: str
    request_id: str | None


class ErrorResponse(BaseModel):
    error: ErrorDetail


def _provider_error_response(
    request: Request,
    exc: LLMProviderError,
    status_code: int,
    code: str,
    message: str,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    request.state.error_type = type(exc).__name__
    return JSONResponse(
        status_code=status_code,
        headers=headers,
        content={
            "error": {
                "code": code,
                "message": message,
                "request_id": getattr(request.state, "request_id", None),
            }
        },
    )


@app.exception_handler(BedrockResponseError)
async def handle_provider_response_error(
    request: Request,
    exc: BedrockResponseError,
) -> JSONResponse:
    return _provider_error_response(
        request=request,
        exc=exc,
        status_code=502,
        code="invalid_model_response",
        message="The model service returned an invalid response.",
    )


@app.exception_handler(LLMProviderError)
async def handle_provider_error(
    request: Request,
    exc: LLMProviderError,
) -> JSONResponse:
    return _provider_error_response(
        request=request,
        exc=exc,
        status_code=503,
        code="llm_provider_unavailable",
        message="The model service is temporarily unavailable.",
        headers={"Retry-After": "5"},
    )


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


@app.post(
    "/v1/generate",
    response_model=GenerateResponse,
    responses={
        502: {
            "model": ErrorResponse,
            "description": "The model returned an invalid response.",
        },
        503: {
            "model": ErrorResponse,
            "description": "The model provider is temporarily unavailable.",
        },
    },
)
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
