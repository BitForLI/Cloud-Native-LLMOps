from dataclasses import dataclass
from datetime import UTC, datetime

from services.common.llm.base import LLMProviderError, LLMResult
from services.worker.app.aws_jobs import ReceivedJob
from services.worker.app.jobs import JobRecord, JobStatus, JobTask
from services.worker.app.worker import DurableJobProcessor

JOB_ID = "0198ab9a-b91c-7000-8000-000000000001"


def record(status):
    now = datetime.now(UTC)
    return JobRecord(JOB_ID, status, now, now)


class Repository:
    def __init__(self, status=JobStatus.PENDING):
        self.status = status
        self.calls = []

    def get(self, job_id):
        self.calls.append(("get", job_id))
        return record(self.status)

    def mark_running(self, job_id):
        self.calls.append(("running", job_id))
        self.status = JobStatus.RUNNING

    def mark_succeeded(self, job_id, outcome):
        self.calls.append(("succeeded", job_id, outcome))
        self.status = JobStatus.SUCCEEDED

    def mark_failed(self, job_id, failure):
        self.calls.append(("failed", job_id, failure))
        self.status = JobStatus.FAILED


class Queue:
    def __init__(self):
        self.deleted = []

    def delete(self, receipt):
        self.deleted.append(receipt)


@dataclass
class Provider:
    error: Exception | None = None
    calls: int = 0
    model_id: str = "model"

    def generate(self, prompt):
        self.calls += 1
        if self.error:
            raise self.error
        return LLMResult("answer", self.model_id, 2, 1, 0.01)


def message(receive_count=1):
    return ReceivedJob(JobTask(JOB_ID, "private"), "receipt", "message", receive_count)


def test_success_is_persisted_before_message_acknowledgement():
    repository, queue, provider = Repository(), Queue(), Provider()

    DurableJobProcessor(repository, queue, provider, 5).process(message())

    assert [call[0] for call in repository.calls] == ["get", "running", "succeeded"]
    assert queue.deleted == ["receipt"]


def test_transient_provider_failure_is_retried_without_ack_or_terminal_state():
    repository, queue = Repository(), Queue()
    provider = Provider(error=LLMProviderError("credential=secret"))

    DurableJobProcessor(repository, queue, provider, 5).process(message(2))

    assert repository.status is JobStatus.RUNNING
    assert queue.deleted == []
    assert not any(call[0] == "failed" for call in repository.calls)


def test_final_attempt_marks_failed_but_remains_for_dlq_redrive(caplog):
    repository, queue = Repository(), Queue()
    provider = Provider(error=LLMProviderError("credential=secret private"))

    DurableJobProcessor(repository, queue, provider, 5).process(message(5))

    assert repository.status is JobStatus.FAILED
    assert repository.calls[-1][2].error_code == "provider_error"
    assert queue.deleted == []
    assert "credential=secret" not in caplog.text
    assert "private" not in caplog.text


def test_duplicate_success_is_acknowledged_without_second_model_call():
    repository, queue, provider = Repository(JobStatus.SUCCEEDED), Queue(), Provider()

    DurableJobProcessor(repository, queue, provider, 5).process(message(2))

    assert provider.calls == 0
    assert queue.deleted == ["receipt"]


def test_final_failed_delivery_is_not_acknowledged_before_dlq_redrive():
    repository, queue, provider = Repository(JobStatus.FAILED), Queue(), Provider()

    DurableJobProcessor(repository, queue, provider, 5).process(message(6))

    assert provider.calls == 0
    assert queue.deleted == []
