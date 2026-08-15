import time
from functools import lru_cache
from threading import BoundedSemaphore, Event, Lock, Thread

from app.metrics import Metrics, get_metrics
from app.providers.base import LLMProvider, LLMProviderError
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


@lru_cache
def get_job_service() -> LocalJobService:
    return LocalJobService(WorkerSettings.from_env())


def reset_job_service() -> None:
    if get_job_service.cache_info().currsize:
        get_job_service().shutdown()
    get_job_service.cache_clear()
