import time
from functools import lru_cache
from threading import BoundedSemaphore, Event, Lock, Thread
from typing import Annotated, Protocol

import boto3
from botocore.config import Config
from fastapi import Depends

from app.config import Settings, get_settings
from app.metrics import Metrics, get_metrics
from app.providers.base import LLMProvider, LLMProviderError
from services.worker.app.aws_jobs import (
    DurableJobStoreError,
    DynamoDBJobRepository,
    SQSJobQueue,
)
from services.worker.app.config import WorkerSettings
from services.worker.app.jobs import (
    InMemoryJobQueue,
    InMemoryJobRepository,
    JobCapacityError,
    JobRecord,
    JobTask,
    handle_job_failure,
    poll_jobs,
    process_inference_job,
)


class JobService(Protocol):
    def submit(self, prompt: str, provider: LLMProvider) -> JobRecord: ...

    def get(self, job_id: str) -> JobRecord: ...

    def check_ready(self) -> None: ...

    def shutdown(self, wait: bool = True) -> None: ...


_created_services: list[JobService] = []


class LocalJobService:
    """Bounded process-local executor behind an SQS-replaceable queue boundary."""

    def __init__(
        self,
        settings: WorkerSettings,
        metrics: Metrics | None = None,
    ) -> None:
        self._settings = settings
        self._metrics = metrics or get_metrics()
        self._repository = InMemoryJobRepository(settings.max_stored_jobs)
        self._queue = InMemoryJobQueue(settings.max_pending_jobs)
        self._capacity = BoundedSemaphore(settings.max_pending_jobs)
        self._providers: dict[str, LLMProvider] = {}
        self._state_lock = Lock()
        self._closed = False
        self._stop_event = Event()
        self._threads = [
            Thread(
                target=self._worker_loop,
                name=f"local-inference-worker-{index}",
                daemon=True,
            )
            for index in range(settings.max_workers)
        ]
        for thread in self._threads:
            thread.start()

    def submit(self, prompt: str, provider: LLMProvider) -> JobRecord:
        with self._state_lock:
            if self._closed:
                raise JobCapacityError("The local job executor is closed.")
            if not self._capacity.acquire(blocking=False):
                raise JobCapacityError("The local job executor is at capacity.")
            try:
                job = self._repository.create()
                self._providers[job.job_id] = provider
                self._queue.put(JobTask(job_id=job.job_id, prompt=prompt))
                return job
            except Exception:
                self._capacity.release()
                raise

    def get(self, job_id: str) -> JobRecord:
        return self._repository.get(job_id)

    def check_ready(self) -> None:
        if self._closed:
            raise JobCapacityError("The local job executor is closed.")

    def shutdown(self, wait: bool = True) -> None:
        with self._state_lock:
            if self._closed:
                return
            self._closed = True
        if wait:
            self._queue.join()
        self._stop_event.set()
        for thread in self._threads:
            thread.join(timeout=self._settings.poll_interval_seconds * 2 + 0.1)

    def _worker_loop(self) -> None:
        while not self._stop_event.is_set():
            task = poll_jobs(self._queue, self._settings.poll_interval_seconds)
            if task is None:
                continue
            self._execute(task)

    def _execute(self, task: JobTask) -> None:
        started = time.perf_counter()
        try:
            with self._state_lock:
                provider = self._providers.pop(task.job_id)
            self._repository.mark_running(task.job_id)
            outcome = process_inference_job(task, provider.generate)
            self._repository.mark_succeeded(task.job_id, outcome)
            if outcome.input_tokens is not None and outcome.output_tokens is not None:
                self._metrics.record_token_usage(
                    outcome.input_tokens, outcome.output_tokens
                )
            if outcome.estimated_cost is not None:
                self._metrics.record_estimated_cost(outcome.estimated_cost)
        except Exception as error:  # noqa: BLE001 - final background-task boundary
            self._metrics.record_model_error()
            error_code = (
                "provider_error"
                if isinstance(error, LLMProviderError)
                else "internal_error"
            )
            self._repository.mark_failed(
                task.job_id,
                handle_job_failure(task, error, error_code=error_code),
            )
        finally:
            self._metrics.record_llm_latency((time.perf_counter() - started) * 1000)
            self._queue.task_done()
            self._capacity.release()


class AwsJobService:
    """Persist job state before publishing work to the durable SQS queue."""

    def __init__(
        self,
        repository: DynamoDBJobRepository,
        queue: SQSJobQueue,
    ) -> None:
        self._repository = repository
        self._queue = queue

    def submit(self, prompt: str, provider: LLMProvider) -> JobRecord:
        del provider  # The independent worker owns model invocation in AWS mode.
        record = self._repository.create()
        task = JobTask(record.job_id, prompt)
        try:
            self._queue.publish(task)
        except DurableJobStoreError:
            # Avoid leaving an indefinitely pending record when enqueueing fails.
            self._repository.mark_failed(
                record.job_id,
                handle_job_failure(task, RuntimeError(), error_code="enqueue_failed"),
            )
            raise
        return record

    def get(self, job_id: str) -> JobRecord:
        return self._repository.get(job_id)

    def check_ready(self) -> None:
        self._repository.check_ready()
        self._queue.check_ready()

    def shutdown(self, wait: bool = True) -> None:
        del wait


def get_job_service(
    settings: Annotated[Settings, Depends(get_settings)],
) -> JobService:
    return _get_cached_job_service(settings.dependency_cache_json())


@lru_cache(maxsize=8)
def _get_cached_job_service(serialized_settings: str) -> JobService:
    settings = Settings.model_validate_json(serialized_settings)
    if settings.job_backend == "memory":
        service: JobService = LocalJobService(WorkerSettings.from_env())
    else:
        aws_config = Config(
            connect_timeout=5,
            read_timeout=25,
            retries={"max_attempts": 3, "mode": "standard"},
        )
        dynamodb = boto3.client(
            "dynamodb", region_name=settings.aws_region, config=aws_config
        )
        sqs = boto3.client("sqs", region_name=settings.aws_region, config=aws_config)
        service = AwsJobService(
            DynamoDBJobRepository(
                dynamodb,
                settings.job_table_name or "",
                ttl_seconds=settings.job_ttl_seconds,
            ),
            SQSJobQueue(sqs, settings.inference_queue_url or ""),
        )
    _created_services.append(service)
    return service


def reset_job_service() -> None:
    for service in _created_services:
        service.shutdown()
    _created_services.clear()
    _get_cached_job_service.cache_clear()
