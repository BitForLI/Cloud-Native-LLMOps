import time
from typing import Annotated

from fastapi import Depends, FastAPI, Request
from pydantic import BaseModel, Field

from app.config import Settings, get_settings
from app.logging import configure_logging
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


@app.get("/health")
def health(settings: Annotated[Settings, Depends(get_settings)]) -> dict[str, str]:
    return {"status": "ok", "environment": settings.app_env}


@app.get("/ready")
def ready() -> dict[str, str]:
    # Extend with Bedrock, DynamoDB, and S3 dependency checks during AWS integration.
    return {"status": "ready"}


@app.post("/v1/generate", response_model=GenerateResponse)
def generate(
    payload: GenerateRequest,
    request: Request,
    provider: Annotated[LLMProvider, Depends(get_provider)],
) -> GenerateResponse:
    request.state.model_id = provider.model_id
    started = time.perf_counter()
    output = provider.generate(payload.prompt)
    latency_ms = round((time.perf_counter() - started) * 1000)
    return GenerateResponse(
        output=output,
        model=provider.model_id,
        latency_ms=latency_ms,
    )
