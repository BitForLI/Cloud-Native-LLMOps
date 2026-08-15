import logging
import os
import signal
import time
from collections.abc import Callable
from pathlib import Path
from threading import Event

from services.worker.app.config import WorkerSettings
from services.worker.app.jobs import (
    InMemoryJobQueue,
    JobTask,
    handle_job_failure,
    poll_jobs,
    process_inference_job,
)

logger = logging.getLogger("llmops.worker")

__all__ = [
    "handle_job_failure",
    "main",
    "poll_jobs",
    "process_inference_job",
    "run_worker",
    "write_heartbeat",
]


def write_heartbeat(path: Path) -> None:
    """Atomically update the worker heartbeat consumed by its health check."""

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(".tmp")
    temporary_path.write_text(str(time.time()), encoding="utf-8")
    temporary_path.replace(path)


def run_worker(
    stop_event: Event,
    heartbeat_path: Path,
    interval_seconds: float,
    job_queue: InMemoryJobQueue | None = None,
    processor: Callable[[JobTask], None] | None = None,
    poll_interval_seconds: float = 0.25,
) -> None:
    """Run heartbeat and optional queue consumption until graceful shutdown."""

    if interval_seconds <= 0 or poll_interval_seconds <= 0:
        raise ValueError("Worker intervals must be positive.")
    if (job_queue is None) is not (processor is None):
        raise ValueError("job_queue and processor must be configured together")

    logger.info("Worker started; waiting for asynchronous inference jobs.")
    next_heartbeat = 0.0
    while not stop_event.is_set():
        now = time.monotonic()
        if now >= next_heartbeat:
            write_heartbeat(heartbeat_path)
            next_heartbeat = now + interval_seconds

        if job_queue is None:
            stop_event.wait(min(interval_seconds, poll_interval_seconds))
            continue

        job = poll_jobs(job_queue, poll_interval_seconds)
        if job is None:
            continue
        try:
            processor(job)
        except Exception as error:  # noqa: BLE001 - final worker safety boundary
            failure = handle_job_failure(job, error)
            logger.error(
                "Job %s failed with code %s (%s).",
                job.job_id,
                failure.error_code,
                type(error).__name__,
            )
        finally:
            job_queue.task_done()
    logger.info("Worker stopped cleanly.")


def _install_signal_handlers(stop_event: Event) -> None:
    def request_shutdown(signum, _frame) -> None:
        logger.info("Worker received shutdown signal %s.", signum)
        stop_event.set()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)


def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = WorkerSettings.from_env()
    stop_event = Event()
    _install_signal_handlers(stop_event)
    # The standalone container receives an SQS queue adapter in the AWS phase.
    run_worker(
        stop_event,
        settings.heartbeat_path,
        settings.heartbeat_interval_seconds,
        poll_interval_seconds=settings.poll_interval_seconds,
    )


if __name__ == "__main__":
    main()
