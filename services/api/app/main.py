import time
from typing import Annotated

from fastapi import Depends, FastAPI
from pydantic import BaseModel, Field

from app.config import Settings, get_settings
from app.providers.base import LLMProvider
from app.providers.factory import get_provider

app = FastAPI(title="LLMOps Inference API", version="0.1.0")


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
    request: GenerateRequest,
    settings: Annotated[Settings, Depends(get_settings)],
    provider: Annotated[LLMProvider, Depends(get_provider)],
) -> GenerateResponse:
    started = time.perf_counter()
    output = provider.generate(request.prompt)
    latency_ms = round((time.perf_counter() - started) * 1000)
    return GenerateResponse(
        output=output,
        model=settings.bedrock_model_id,
        latency_ms=latency_ms,
    )
