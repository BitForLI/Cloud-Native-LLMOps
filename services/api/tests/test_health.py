from app.main import app
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

        def generate(self, prompt: str) -> str:
            return f"fake response for {prompt}"

    app.dependency_overrides[get_provider] = FakeProvider
    try:
        response = client.post("/v1/generate", json={"prompt": "delegation"})
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()["output"] == "fake response for delegation"
    assert response.json()["model"] == "fake-model"
