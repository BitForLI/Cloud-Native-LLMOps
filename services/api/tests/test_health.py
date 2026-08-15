from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_is_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_generate_returns_deterministic_response():
    response = client.post("/v1/generate", json={"prompt": "hello"})
    assert response.status_code == 200
    assert response.json()["output"] == "Received: hello"

