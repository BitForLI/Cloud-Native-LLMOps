import app.middleware as middleware_module
from app.main import app
from app.metrics import get_metrics
from app.providers.base import LLMProviderError, LLMResult
from app.providers.bedrock import BedrockInvocationError, BedrockResponseError
from fastapi.testclient import TestClient


class FailingProvider:
    model_id = "failing-model"

    def __init__(self, error):
        self.error = error

    def generate(self, prompt: str) -> LLMResult:
        raise self.error


def test_invocation_error_returns_safe_503_with_request_id(
    client,
    override_provider,
    monkeypatch,
):
    logs = []
    override_provider(
        FailingProvider(BedrockInvocationError("secret AWS account detail"))
    )
    monkeypatch.setattr(
        middleware_module.logger,
        "error",
        lambda message, **kwargs: logs.append(kwargs["extra"]),
    )

    response = client.post(
        "/v1/generate",
        json={"prompt": "hello"},
        headers={"X-Request-ID": "error-123"},
    )

    assert response.status_code == 503
    assert response.headers["X-Request-ID"] == "error-123"
    assert response.headers["Retry-After"] == "5"
    assert response.json() == {
        "error": {
            "code": "llm_provider_unavailable",
            "message": "The model service is temporarily unavailable.",
            "request_id": "error-123",
        }
    }
    assert "secret AWS account detail" not in response.text
    assert logs[0]["error_type"] == "BedrockInvocationError"
    assert logs[0]["model"] == "failing-model"

    snapshot = get_metrics().snapshot()
    assert snapshot.request_count == 1
    assert snapshot.error_count == 1
    assert snapshot.model_error_count == 1


def test_invalid_model_response_returns_safe_502(client, override_provider):
    override_provider(FailingProvider(BedrockResponseError("raw model payload")))

    response = client.post("/v1/generate", json={"prompt": "hello"})

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "invalid_model_response"
    assert "raw model payload" not in response.text


def test_generic_provider_error_uses_provider_handler(client, override_provider):
    override_provider(FailingProvider(LLMProviderError("private provider detail")))

    response = client.post("/v1/generate", json={"prompt": "hello"})

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "llm_provider_unavailable"
    assert "private provider detail" not in response.text


def test_unexpected_error_remains_generic_500(override_provider):
    override_provider(FailingProvider(RuntimeError("internal secret")))

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post("/v1/generate", json={"prompt": "hello"})

    assert response.status_code == 500
    assert "internal secret" not in response.text
