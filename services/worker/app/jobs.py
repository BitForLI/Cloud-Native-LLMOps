from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from enum import StrEnum
from queue import Empty, Full, Queue
from threading import RLock
from typing import Protocol
from uuid import uuid4


class JobStatus(StrEnum):
    PENDING = "pending"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


TERMINAL_STATUSES = {JobStatus.SUCCEEDED, JobStatus.FAILED}


@dataclass(frozen=True, slots=True)
class JobRecord:
    job_id: str
    status: JobStatus
    created_at: datetime
    updated_at: datetime
    output: str | None = None
    model_id: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    estimated_cost: float | None = None
    error_code: str | None = None


@dataclass(frozen=True, slots=True)
class JobTask:
    job_id: str
    prompt: str
    trace_context: dict[str, str] | None = None


@dataclass(frozen=True, slots=True)
class JobOutcome:
    output: str
    model_id: str
    input_tokens: int | None = None
    output_tokens: int | None = None
    estimated_cost: float | None = None


@dataclass(frozen=True, slots=True)
class JobFailure:
    error_code: str


class GenerationResult(Protocol):
    output: str
    model_id: str
    input_tokens: int | None
    output_tokens: int | None
    estimated_cost: float | None


class JobNotFoundError(LookupError):
    pass


class JobCapacityError(RuntimeError):
    pass


class InvalidJobTransitionError(RuntimeError):
    pass


class InMemoryJobRepository:
    """Thread-safe bounded repository; prompts are deliberately not retained."""

    def __init__(self, max_stored_jobs: int = 1000) -> None:
        if max_stored_jobs < 1:
            raise ValueError("max_stored_jobs must be positive")
        self._max_stored_jobs = max_stored_jobs
        self._jobs: OrderedDict[str, JobRecord] = OrderedDict()
        self._lock = RLock()

    def create(self, job_id: str | None = None) -> JobRecord:
        with self._lock:
            self._evict_terminal_jobs_for_space()
            if len(self._jobs) >= self._max_stored_jobs:
                raise JobCapacityError("Job history capacity has been reached.")
            now = datetime.now(UTC)
            record = JobRecord(
                job_id=job_id or str(uuid4()),
                status=JobStatus.PENDING,
                created_at=now,
                updated_at=now,
            )
            if record.job_id in self._jobs:
                raise ValueError("job_id must be unique")
            self._jobs[record.job_id] = record
            return record

    def get(self, job_id: str) -> JobRecord:
        with self._lock:
            try:
                return self._jobs[job_id]
            except KeyError as exc:
                raise JobNotFoundError(job_id) from exc

    def mark_running(self, job_id: str) -> JobRecord:
        return self._transition(job_id, JobStatus.PENDING, status=JobStatus.RUNNING)

    def mark_succeeded(self, job_id: str, outcome: JobOutcome) -> JobRecord:
        return self._transition(
            job_id,
            JobStatus.RUNNING,
            status=JobStatus.SUCCEEDED,
            output=outcome.output,
            model_id=outcome.model_id,
            input_tokens=outcome.input_tokens,
            output_tokens=outcome.output_tokens,
            estimated_cost=outcome.estimated_cost,
        )

    def mark_failed(self, job_id: str, failure: JobFailure) -> JobRecord:
        with self._lock:
            current = self.get(job_id)
            if current.status not in {JobStatus.PENDING, JobStatus.RUNNING}:
                raise InvalidJobTransitionError(
                    f"Cannot transition {current.status} job to failed."
                )
            updated = replace(
                current,
                status=JobStatus.FAILED,
                updated_at=datetime.now(UTC),
                error_code=failure.error_code,
            )
            self._jobs[job_id] = updated
            return updated

    def _transition(
        self,
        job_id: str,
        expected_status: JobStatus,
        **changes: object,
    ) -> JobRecord:
        with self._lock:
            current = self.get(job_id)
            if current.status is not expected_status:
                raise InvalidJobTransitionError(
                    f"Expected {expected_status} job, found {current.status}."
                )
            updated = replace(current, updated_at=datetime.now(UTC), **changes)
            self._jobs[job_id] = updated
            return updated

    def _evict_terminal_jobs_for_space(self) -> None:
        while len(self._jobs) >= self._max_stored_jobs:
            terminal_job_id = next(
                (
                    job_id
                    for job_id, job in self._jobs.items()
                    if job.status in TERMINAL_STATUSES
                ),
                None,
            )
            if terminal_job_id is None:
                return
            del self._jobs[terminal_job_id]


class InMemoryJobQueue:
    """Bounded local queue with an interface replaceable by an SQS adapter."""

    def __init__(self, max_pending_jobs: int = 100) -> None:
        if max_pending_jobs < 1:
            raise ValueError("max_pending_jobs must be positive")
        self._queue: Queue[JobTask] = Queue(maxsize=max_pending_jobs)

    def put(self, job: JobTask) -> None:
        try:
            self._queue.put_nowait(job)
        except Full as exc:
            raise JobCapacityError("The local job queue is full.") from exc

    def poll(self, timeout_seconds: float) -> JobTask | None:
        try:
            return self._queue.get(timeout=timeout_seconds)
        except Empty:
            return None

    def task_done(self) -> None:
        self._queue.task_done()

    def join(self) -> None:
        self._queue.join()


def poll_jobs(
    job_queue: InMemoryJobQueue, timeout_seconds: float = 0.25
) -> JobTask | None:
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    return job_queue.poll(timeout_seconds)


def process_inference_job(
    job: JobTask,
    generate: Callable[[str], GenerationResult],
) -> JobOutcome:
    result = generate(job.prompt)
    if not result.output or not result.model_id:
        raise ValueError("The model result must include output and model_id.")
    return JobOutcome(
        output=result.output,
        model_id=result.model_id,
        input_tokens=result.input_tokens,
        output_tokens=result.output_tokens,
        estimated_cost=result.estimated_cost,
    )


def handle_job_failure(
    job: JobTask,
    error: Exception,
    error_code: str = "internal_error",
) -> JobFailure:
    """Return a public failure without retaining the prompt or exception message."""

    del job, error
    return JobFailure(error_code=error_code)
