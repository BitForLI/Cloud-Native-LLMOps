import time

from fastapi import Depends, FastAPI
from pydantic import BaseModel, Field

from app.config import Settings, get_settings

app = FastAPI(title="LLMOps Inference API", version="0.1.0")


class GenerateRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=8000)


class GenerateResponse(BaseModel):
    output: str
    model: str
    latency_ms: int


@app.get("/health")
def health(settings: Settings = Depends(get_settings)) -> dict[str, str]:
    return {"status": "ok", "environment": settings.app_env}


@app.get("/ready")
def ready() -> dict[str, str]:
    # Extend with Bedrock, DynamoDB, and S3 dependency checks during AWS integration.
    return {"status": "ready"}


@app.post("/v1/generate", response_model=GenerateResponse)
def generate(
    request: GenerateRequest,
    settings: Settings = Depends(get_settings),
) -> GenerateResponse:
    started = time.perf_counter()
    # A deterministic stub enables safe CI evaluation. Replace with a Bedrock adapter.
    output = f"Received: {request.prompt.strip()}"
    latency_ms = round((time.perf_counter() - started) * 1000)
    return GenerateResponse(
        output=output,
        model=settings.bedrock_model_id,
        latency_ms=latency_ms,
    )
