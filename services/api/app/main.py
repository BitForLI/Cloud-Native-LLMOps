import time
from datetime import datetime
from typing import Annotated

from fastapi import Depends, FastAPI, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.auth import require_api_key
from app.config import Settings, get_settings
from app.job_service import JobService, get_job_service
from app.logging import configure_logging
from app.metrics import Metrics, MetricsSnapshot, get_metrics
from app.middleware import request_context_middleware
from app.providers.base import LLMProvider, LLMProviderError
from app.providers.bedrock import BedrockResponseError
from app.providers.factory import get_provider
from services.common.observability.emf import (
    configure_emf_logging,
    emit_inference_metrics,
)
from services.worker.app.aws_jobs import DurableJobStoreError
from services.worker.app.jobs import (
    JobCapacityError,
    JobNotFoundError,
    JobRecord,
    JobStatus,
)

configure_logging(get_settings().log_level)
configure_emf_logging()
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


class CreateJobRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=8000)


class JobResponse(BaseModel):
    job_id: str
    status: JobStatus
    created_at: datetime
    updated_at: datetime
    output: str | None = None
    model: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    estimated_cost: float | None = None
    error_code: str | None = None

    @classmethod
    def from_record(cls, record: JobRecord) -> "JobResponse":
        return cls(
            job_id=record.job_id,
            status=record.status,
            created_at=record.created_at,
            updated_at=record.updated_at,
            output=record.output,
            model=record.model_id,
            input_tokens=record.input_tokens,
            output_tokens=record.output_tokens,
            estimated_cost=record.estimated_cost,
            error_code=record.error_code,
        )


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


@app.exception_handler(JobNotFoundError)
async def handle_job_not_found(
    request: Request,
    exc: JobNotFoundError,
) -> JSONResponse:
    request.state.error_type = type(exc).__name__
    return JSONResponse(
        status_code=404,
        content={
            "error": {
                "code": "job_not_found",
                "message": "The requested job does not exist.",
                "request_id": getattr(request.state, "request_id", None),
            }
        },
    )


@app.exception_handler(JobCapacityError)
async def handle_job_capacity(
    request: Request,
    exc: JobCapacityError,
) -> JSONResponse:
    request.state.error_type = type(exc).__name__
    return JSONResponse(
        status_code=503,
        headers={"Retry-After": "1"},
        content={
            "error": {
                "code": "job_capacity_exceeded",
                "message": "The job service is temporarily at capacity.",
                "request_id": getattr(request.state, "request_id", None),
            }
        },
    )


@app.exception_handler(DurableJobStoreError)
async def handle_job_store_error(
    request: Request,
    exc: DurableJobStoreError,
) -> JSONResponse:
    request.state.error_type = type(exc).__name__
    return JSONResponse(
        status_code=503,
        headers={"Retry-After": "5"},
        content={
            "error": {
                "code": "job_service_unavailable",
                "message": "The durable job service is temporarily unavailable.",
                "request_id": getattr(request.state, "request_id", None),
            }
        },
    )


@app.get("/health")
def health(settings: Annotated[Settings, Depends(get_settings)]) -> dict[str, str]:
    return {"status": "ok", "environment": settings.app_env}


@app.get("/ready")
def ready(
    job_service: Annotated[JobService, Depends(get_job_service)],
) -> dict[str, str]:
    job_service.check_ready()
    return {"status": "ready"}


@app.get("/metrics", dependencies=[Depends(require_api_key)])
def metrics_snapshot(
    metrics: Annotated[Metrics, Depends(get_metrics)],
) -> MetricsSnapshot:
    return metrics.snapshot()


@app.post(
    "/v1/generate",
    dependencies=[Depends(require_api_key)],
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
    settings: Annotated[Settings, Depends(get_settings)],
) -> GenerateResponse:
    request.state.model_id = provider.model_id
    started = time.perf_counter()
    result = None
    model_error = False
    try:
        result = provider.generate(payload.prompt)
    except Exception:
        model_error = True
        metrics.record_model_error()
        raise
    finally:
        llm_latency_ms = (time.perf_counter() - started) * 1000
        metrics.record_llm_latency(llm_latency_ms)
        emit_inference_metrics(
            service="api",
            environment=settings.app_env,
            model=provider.model_id,
            latency_ms=llm_latency_ms,
            model_error=model_error,
            input_tokens=result.input_tokens if result else None,
            output_tokens=result.output_tokens if result else None,
            estimated_cost_usd=result.estimated_cost if result else None,
        )

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


@app.post(
    "/v1/jobs",
    dependencies=[Depends(require_api_key)],
    response_model=JobResponse,
    status_code=status.HTTP_202_ACCEPTED,
    responses={
        503: {
            "model": ErrorResponse,
            "description": "The bounded local job executor is at capacity.",
        }
    },
)
def create_job(
    payload: CreateJobRequest,
    request: Request,
    provider: Annotated[LLMProvider, Depends(get_provider)],
    job_service: Annotated[JobService, Depends(get_job_service)],
) -> JobResponse:
    request.state.model_id = provider.model_id
    return JobResponse.from_record(job_service.submit(payload.prompt, provider))


@app.get(
    "/v1/jobs/{job_id}",
    dependencies=[Depends(require_api_key)],
    response_model=JobResponse,
    responses={404: {"model": ErrorResponse, "description": "The job does not exist."}},
)
def get_job(
    job_id: str,
    job_service: Annotated[JobService, Depends(get_job_service)],
) -> JobResponse:
    return JobResponse.from_record(job_service.get(job_id))
