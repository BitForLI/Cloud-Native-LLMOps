from app.config import Settings, get_settings
from app.main import app


def protected_settings() -> Settings:
    return Settings(
        app_env="production",
        api_auth_token="a" * 32,
        otel_exporter_otlp_endpoint="http://127.0.0.1:4317",
        _env_file=None,
    )


def test_health_and_readiness_remain_available_without_credentials(client):
    app.dependency_overrides[get_settings] = protected_settings

    assert client.get("/health").status_code == 200
    assert client.get("/ready").status_code == 200


def test_protected_endpoints_reject_missing_or_invalid_key(client):
    app.dependency_overrides[get_settings] = protected_settings

    for path in ("/metrics", "/v1/jobs/missing"):
        response = client.get(path)
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "ApiKey"

    response = client.post("/v1/jobs", json={"prompt": "hello"})
    assert response.status_code == 401

    response = client.post(
        "/v1/generate",
        headers={"X-API-Key": "wrong"},
        json={"prompt": "hello"},
    )
    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid or missing API key."}


def test_protected_endpoint_accepts_exact_key(client):
    app.dependency_overrides[get_settings] = protected_settings

    response = client.post(
        "/v1/generate",
        headers={"X-API-Key": "a" * 32},
        json={"prompt": "authenticated"},
    )

    assert response.status_code == 200
    assert response.json()["output"] == "Received: authenticated"
