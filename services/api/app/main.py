import time
from os import getenv

from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(title="LLMOps Inference API", version="0.1.0")


class GenerateRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=8000)


class GenerateResponse(BaseModel):
    output: str
    model: str
    latency_ms: int


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "environment": getenv("APP_ENV", "local")}


@app.get("/ready")
def ready() -> dict[str, str]:
    # Extend with Bedrock, DynamoDB, and S3 dependency checks during AWS integration.
    return {"status": "ready"}


@app.post("/v1/generate", response_model=GenerateResponse)
def generate(request: GenerateRequest) -> GenerateResponse:
    started = time.perf_counter()
    model = getenv("BEDROCK_MODEL_ID", "local-deterministic-stub")
    # A deterministic stub enables safe CI evaluation. Replace with a Bedrock adapter.
    output = f"Received: {request.prompt.strip()}"
    latency_ms = round((time.perf_counter() - started) * 1000)
    return GenerateResponse(output=output, model=model, latency_ms=latency_ms)

