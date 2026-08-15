import pytest

from services.worker.app.config import WorkerSettings


def test_worker_settings_load_validated_environment(monkeypatch):
    monkeypatch.setenv("JOB_MAX_WORKERS", "3")
    monkeypatch.setenv("JOB_MAX_PENDING", "7")
    monkeypatch.setenv("JOB_MAX_STORED", "20")
    monkeypatch.setenv("APP_ENV", "staging")

    settings = WorkerSettings.from_env()

    assert settings.max_workers == 3
    assert settings.max_pending_jobs == 7
    assert settings.max_stored_jobs == 20
    assert settings.app_env == "staging"


@pytest.mark.parametrize("value", ["0", "not-a-number"])
def test_worker_settings_reject_invalid_worker_count(monkeypatch, value):
    monkeypatch.setenv("JOB_MAX_WORKERS", value)

    with pytest.raises(ValueError, match="JOB_MAX_WORKERS"):
        WorkerSettings.from_env()


def test_worker_settings_reject_history_smaller_than_queue():
    with pytest.raises(ValueError, match="at least"):
        WorkerSettings(max_pending_jobs=2, max_stored_jobs=1)


def test_aws_worker_requires_local_trace_collector():
    with pytest.raises(ValueError, match="OTEL_EXPORTER_OTLP_ENDPOINT"):
        WorkerSettings(
            job_backend="aws",
            job_table_name="jobs",
            inference_queue_url="https://sqs.example/jobs",
        )

    settings = WorkerSettings(
        job_backend="aws",
        job_table_name="jobs",
        inference_queue_url="https://sqs.example/jobs",
        otel_exporter_otlp_endpoint="http://127.0.0.1:4317",
        otel_trace_sample_ratio=0.25,
    )
    assert settings.otel_trace_sample_ratio == 0.25
