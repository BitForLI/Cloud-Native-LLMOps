from uuid import UUID

import app.middleware as middleware_module
from app.logging import current_request_id
from app.main import app
from app.providers.factory import get_provider
from fastapi.testclient import TestClient

client = TestClient(app)


def test_middleware_returns_supplied_request_id(monkeypatch):
    logs = []
    monkeypatch.setattr(
        middleware_module.logger,
        "info",
        lambda message, **kwargs: logs.append((message, kwargs["extra"])),
    )

    response = client.get("/health", headers={"X-Request-ID": "caller-123"})

    assert response.headers["X-Request-ID"] == "caller-123"
    assert logs == [
        (
            "Request completed",
            {
                "event": "http_request_completed",
                "method": "GET",
                "route": "/health",
                "status_code": 200,
                "latency_ms": logs[0][1]["latency_ms"],
                "model": None,
                "error_type": None,
            },
        )
    ]
    assert logs[0][1]["latency_ms"] >= 0
    assert current_request_id() == "-"


def test_middleware_replaces_invalid_request_id():
    response = client.get("/health", headers={"X-Request-ID": "invalid id"})

    generated = response.headers["X-Request-ID"]
    assert generated != "invalid id"
    assert str(UUID(generated)) == generated


def test_generate_log_includes_model_without_prompt(monkeypatch):
    logs = []
    monkeypatch.setattr(
        middleware_module.logger,
        "info",
        lambda message, **kwargs: logs.append(kwargs["extra"]),
    )

    response = client.post("/v1/generate", json={"prompt": "private prompt"})

    assert response.status_code == 200
    assert logs[0]["model"] == "local-deterministic-stub"
    assert "private prompt" not in str(logs[0])


def test_failed_request_logs_error_type(monkeypatch):
    logs = []

    class FailingProvider:
        model_id = "failing-model"

        def generate(self, prompt: str) -> str:
            raise RuntimeError("provider unavailable")

    monkeypatch.setattr(
        middleware_module.logger,
        "exception",
        lambda message, **kwargs: logs.append((message, kwargs["extra"])),
    )
    app.dependency_overrides[get_provider] = FailingProvider
    try:
        response = TestClient(app, raise_server_exceptions=False).post(
            "/v1/generate",
            json={"prompt": "hello"},
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 500
    assert logs[0][0] == "Request failed"
    assert logs[0][1]["status_code"] == 500
    assert logs[0][1]["model"] == "failing-model"
    assert logs[0][1]["error_type"] == "RuntimeError"
    assert current_request_id() == "-"
