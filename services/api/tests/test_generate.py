import pytest
from app.metrics import get_metrics
from app.providers.base import LLMResult


class RecordingProvider:
    model_id = "integration-model"

    def __init__(self):
        self.prompts = []

    def generate(self, prompt: str) -> LLMResult:
        self.prompts.append(prompt)
        return LLMResult(
            output=f"generated: {prompt}",
            model_id=self.model_id,
            input_tokens=12,
            output_tokens=7,
            estimated_cost=0.00004,
        )


def test_generate_exercises_provider_metrics_and_response_contract(
    client,
    override_provider,
):
    provider = RecordingProvider()
    override_provider(provider)

    response = client.post(
        "/v1/generate",
        json={"prompt": "integration test"},
        headers={"X-Request-ID": "integration-123"},
    )

    assert response.status_code == 200
    assert response.headers["X-Request-ID"] == "integration-123"
    assert provider.prompts == ["integration test"]
    assert response.json() == {
        "output": "generated: integration test",
        "model": "integration-model",
        "latency_ms": response.json()["latency_ms"],
        "input_tokens": 12,
        "output_tokens": 7,
        "estimated_cost": 0.00004,
    }
    assert response.json()["latency_ms"] >= 0

    snapshot = get_metrics().snapshot()
    assert snapshot.request_count == 1
    assert snapshot.llm_request_count == 1
    assert snapshot.input_tokens_total == 12
    assert snapshot.output_tokens_total == 7
    assert snapshot.estimated_llm_cost_usd == 0.00004


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"prompt": ""},
        {"prompt": "x" * 8_001},
        {"prompt": 123},
    ],
)
def test_generate_rejects_invalid_payload_before_provider_call(
    client,
    override_provider,
    payload,
):
    provider = RecordingProvider()
    override_provider(provider)

    response = client.post("/v1/generate", json=payload)

    assert response.status_code == 422
    assert provider.prompts == []
    assert get_metrics().snapshot().llm_request_count == 0


def test_generate_uses_local_provider_by_default(client):
    response = client.post("/v1/generate", json={"prompt": "hello"})

    assert response.status_code == 200
    assert response.json()["output"] == "Received: hello"
    assert response.json()["model"] == "local-deterministic-stub"


def test_openapi_documents_provider_error_contracts(client):
    operation = client.get("/openapi.json").json()["paths"]["/v1/generate"]["post"]

    assert "502" in operation["responses"]
    assert "503" in operation["responses"]
