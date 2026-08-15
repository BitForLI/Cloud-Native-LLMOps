from dataclasses import dataclass

import pytest

from services.worker.app.jobs import (
    InMemoryJobQueue,
    InMemoryJobRepository,
    InvalidJobTransitionError,
    JobCapacityError,
    JobOutcome,
    JobStatus,
    JobTask,
    handle_job_failure,
    poll_jobs,
    process_inference_job,
)


@dataclass
class Result:
    output: str = "answer"
    model_id: str = "test-model"
    input_tokens: int | None = 3
    output_tokens: int | None = 2
    estimated_cost: float | None = 0.01


def test_repository_enforces_success_state_machine():
    repository = InMemoryJobRepository(max_stored_jobs=2)
    created = repository.create("job-1")
    running = repository.mark_running(created.job_id)
    succeeded = repository.mark_succeeded(
        created.job_id,
        JobOutcome("answer", "model", 3, 2, 0.01),
    )

    assert created.status is JobStatus.PENDING
    assert running.status is JobStatus.RUNNING
    assert succeeded.status is JobStatus.SUCCEEDED
    assert succeeded.output == "answer"
    assert succeeded.updated_at >= succeeded.created_at
    with pytest.raises(InvalidJobTransitionError):
        repository.mark_running(created.job_id)


def test_repository_evicts_oldest_terminal_job_but_not_active_job():
    repository = InMemoryJobRepository(max_stored_jobs=1)
    first = repository.create("first")

    with pytest.raises(JobCapacityError):
        repository.create("blocked")

    repository.mark_failed(
        first.job_id, handle_job_failure(JobTask("first", "x"), RuntimeError())
    )
    second = repository.create("second")

    assert second.job_id == "second"
    with pytest.raises(LookupError):
        repository.get("first")


def test_bounded_queue_polls_in_order_and_rejects_overflow():
    queue = InMemoryJobQueue(max_pending_jobs=1)
    task = JobTask("job-1", "prompt")
    queue.put(task)

    with pytest.raises(JobCapacityError):
        queue.put(JobTask("job-2", "other"))

    assert poll_jobs(queue, timeout_seconds=0.01) == task
    queue.task_done()
    assert poll_jobs(queue, timeout_seconds=0.01) is None


def test_processing_maps_model_result_and_failure_redacts_details():
    task = JobTask("job-1", "private prompt")

    outcome = process_inference_job(task, lambda prompt: Result(output=prompt))
    failure = handle_job_failure(
        task,
        RuntimeError("credential=very-secret"),
        error_code="provider_error",
    )

    assert outcome.output == "private prompt"
    assert outcome.model_id == "test-model"
    assert failure.error_code == "provider_error"
    assert "secret" not in repr(failure)
