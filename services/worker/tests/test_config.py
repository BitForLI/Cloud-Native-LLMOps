import pytest

from services.worker.app.config import WorkerSettings


def test_worker_settings_load_validated_environment(monkeypatch):
    monkeypatch.setenv("JOB_MAX_WORKERS", "3")
    monkeypatch.setenv("JOB_MAX_PENDING", "7")
    monkeypatch.setenv("JOB_MAX_STORED", "20")

    settings = WorkerSettings.from_env()

    assert settings.max_workers == 3
    assert settings.max_pending_jobs == 7
    assert settings.max_stored_jobs == 20


@pytest.mark.parametrize("value", ["0", "not-a-number"])
def test_worker_settings_reject_invalid_worker_count(monkeypatch, value):
    monkeypatch.setenv("JOB_MAX_WORKERS", value)

    with pytest.raises(ValueError, match="JOB_MAX_WORKERS"):
        WorkerSettings.from_env()


def test_worker_settings_reject_history_smaller_than_queue():
    with pytest.raises(ValueError, match="at least"):
        WorkerSettings(max_pending_jobs=2, max_stored_jobs=1)
