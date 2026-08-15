from app.main import app
from app.providers.base import LLMResult
from app.providers.factory import get_provider
from fastapi.testclient import TestClient

client = TestClient(app)


def test_health_is_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_generate_returns_deterministic_response():
    response = client.post("/v1/generate", json={"prompt": "hello"})
    assert response.status_code == 200
    assert response.json()["output"] == "Received: hello"


def test_generate_delegates_to_provider():
    class FakeProvider:
        model_id = "fake-model"

        def generate(self, prompt: str) -> LLMResult:
            return LLMResult(
                output=f"fake response for {prompt}",
                model_id=self.model_id,
                input_tokens=10,
                output_tokens=4,
                estimated_cost=0.00002,
            )

    app.dependency_overrides[get_provider] = FakeProvider
    try:
        response = client.post("/v1/generate", json={"prompt": "delegation"})
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["output"] == "fake response for delegation"
    assert response.json()["model"] == "fake-model"
    assert response.json()["input_tokens"] == 10
    assert response.json()["output_tokens"] == 4
    assert response.json()["estimated_cost"] == 0.00002
