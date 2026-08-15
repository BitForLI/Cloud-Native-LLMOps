import time
from threading import Event

from app.job_service import LocalJobService, get_job_service
from app.metrics import get_metrics
from app.providers.base import LLMProviderError, LLMResult

from services.worker.app.config import WorkerSettings


class AsyncProvider:
    model_id = "async-model"

    def generate(self, prompt: str) -> LLMResult:
        return LLMResult(
            output=f"async: {prompt}",
            model_id=self.model_id,
            input_tokens=5,
            output_tokens=4,
            estimated_cost=0.002,
        )


class FailingProvider:
    model_id = "failing-model"

    def generate(self, prompt: str) -> LLMResult:
        raise LLMProviderError(f"secret backend detail for {prompt}")


class BlockingProvider:
    model_id = "blocking-model"

    def __init__(self, started: Event, release: Event):
        self.started = started
        self.release = release

    def generate(self, prompt: str) -> LLMResult:
        self.started.set()
        self.release.wait(timeout=2)
        return LLMResult(prompt, self.model_id)


def wait_for_terminal_job(client, job_id: str) -> dict:
    for _ in range(100):
        response = client.get(f"/v1/jobs/{job_id}")
        assert response.status_code == 200
        job = response.json()
        if job["status"] in {"succeeded", "failed"}:
            return job
        time.sleep(0.005)
    raise AssertionError("Job did not reach a terminal state")


def test_async_job_runs_to_success_without_exposing_prompt(client, override_provider):
    override_provider(AsyncProvider())

    submitted = client.post("/v1/jobs", json={"prompt": "private input"})

    assert submitted.status_code == 202
    assert submitted.json()["status"] in {"pending", "running", "succeeded"}
    assert "prompt" not in submitted.json()

    job = wait_for_terminal_job(client, submitted.json()["job_id"])
    assert job == {
        "job_id": submitted.json()["job_id"],
        "status": "succeeded",
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
        "output": "async: private input",
        "model": "async-model",
        "input_tokens": 5,
        "output_tokens": 4,
        "estimated_cost": 0.002,
        "error_code": None,
    }
    snapshot = get_metrics().snapshot()
    assert snapshot.llm_request_count == 1
    assert snapshot.input_tokens_total == 5
    assert snapshot.output_tokens_total == 4


def test_async_failure_is_terminal_and_redacted(client, override_provider):
    override_provider(FailingProvider())
    submitted = client.post("/v1/jobs", json={"prompt": "do-not-return"})

    job = wait_for_terminal_job(client, submitted.json()["job_id"])

    assert job["status"] == "failed"
    assert job["error_code"] == "provider_error"
    assert job["output"] is None
    assert "secret" not in str(job)
    assert "do-not-return" not in str(job)
    assert get_metrics().snapshot().model_error_count == 1


def test_missing_job_uses_structured_404_contract(client):
    response = client.get("/v1/jobs/does-not-exist")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "job_not_found"


def test_capacity_limit_returns_retryable_503(client, override_provider):
    started = Event()
    release = Event()
    provider = BlockingProvider(started, release)
    service = LocalJobService(
        WorkerSettings(
            max_workers=1,
            max_pending_jobs=1,
            max_stored_jobs=2,
            poll_interval_seconds=0.01,
        )
    )
    override_provider(provider)
    client.app.dependency_overrides[get_job_service] = lambda: service

    first = client.post("/v1/jobs", json={"prompt": "first"})
    assert first.status_code == 202
    assert started.wait(timeout=1)

    second = client.post("/v1/jobs", json={"prompt": "second"})
    release.set()
    service.shutdown()

    assert second.status_code == 503
    assert second.headers["Retry-After"] == "1"
    assert second.json()["error"]["code"] == "job_capacity_exceeded"


def test_openapi_documents_async_error_contracts(client):
    paths = client.get("/openapi.json").json()["paths"]

    assert "503" in paths["/v1/jobs"]["post"]["responses"]
    assert "404" in paths["/v1/jobs/{job_id}"]["get"]["responses"]
