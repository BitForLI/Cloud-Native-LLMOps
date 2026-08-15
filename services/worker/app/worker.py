import logging
import os
import signal
import time
from collections.abc import Callable
from pathlib import Path
from threading import Event

import boto3
from botocore.config import Config

from services.common.llm.base import LLMProvider, LLMProviderError
from services.common.llm.bedrock import BedrockProvider
from services.worker.app.aws_jobs import (
    DurableJobStoreError,
    DynamoDBJobRepository,
    InvalidQueueMessageError,
    ReceivedJob,
    SQSJobQueue,
)
from services.worker.app.config import WorkerSettings
from services.worker.app.jobs import (
    InMemoryJobQueue,
    JobStatus,
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
    "run_durable_worker",
    "run_worker",
    "write_heartbeat",
]


class DurableJobProcessor:
    """Process one at-least-once SQS delivery without acknowledging failures."""

    def __init__(
        self,
        repository: DynamoDBJobRepository,
        queue: SQSJobQueue,
        provider: LLMProvider,
        max_receive_count: int,
    ) -> None:
        self._repository = repository
        self._queue = queue
        self._provider = provider
        self._max_receive_count = max_receive_count

    def process(self, message: ReceivedJob) -> None:
        record = self._repository.get(message.task.job_id)
        if record.status is JobStatus.SUCCEEDED:
            self._queue.delete(message.receipt_handle)
            logger.info("Acknowledged duplicate completed job %s.", record.job_id)
            return
        if record.status is JobStatus.FAILED:
            # Final failures remain unacknowledged so the queue redrive policy
            # preserves their message in the DLQ for operational inspection.
            logger.warning("Final failed job %s is awaiting DLQ redrive.", record.job_id)
            return

        try:
            self._repository.mark_running(message.task.job_id)
            outcome = process_inference_job(message.task, self._provider.generate)
            self._repository.mark_succeeded(message.task.job_id, outcome)
            self._queue.delete(message.receipt_handle)
            logger.info("Completed inference job %s.", message.task.job_id)
        except Exception as error:  # noqa: BLE001 - delivery safety boundary
            error_code = (
                "provider_error"
                if isinstance(error, LLMProviderError)
                else "internal_error"
            )
            if message.receive_count >= self._max_receive_count:
                try:
                    self._repository.mark_failed(
                        message.task.job_id,
                        handle_job_failure(message.task, error, error_code),
                    )
                except Exception as update_error:  # noqa: BLE001
                    logger.error(
                        "Could not persist final failure for job %s (%s).",
                        message.task.job_id,
                        type(update_error).__name__,
                    )
            logger.error(
                "Job %s attempt %s failed with code %s (%s); message retained.",
                message.task.job_id,
                message.receive_count,
                error_code,
                type(error).__name__,
            )


def run_durable_worker(
    stop_event: Event,
    heartbeat_path: Path,
    heartbeat_interval_seconds: float,
    wait_time_seconds: int,
    queue: SQSJobQueue,
    processor: DurableJobProcessor,
) -> None:
    """Long-poll SQS while remaining responsive to ECS termination signals."""

    logger.info("Durable SQS inference worker started.")
    next_heartbeat = 0.0
    while not stop_event.is_set():
        now = time.monotonic()
        if now >= next_heartbeat:
            write_heartbeat(heartbeat_path)
            next_heartbeat = now + heartbeat_interval_seconds
        try:
            message = queue.receive(wait_time_seconds)
            if message is not None:
                processor.process(message)
        except InvalidQueueMessageError as error:
            logger.error(
                "Rejected malformed SQS message %s on attempt %s (%s); message retained.",
                error.message_id,
                error.receive_count,
                type(error).__name__,
            )
        except DurableJobStoreError as error:
            logger.error("AWS job transport unavailable (%s).", type(error).__name__)
            stop_event.wait(1.0)
        except Exception as error:  # noqa: BLE001 - top-level process safety boundary
            # Do not emit exception messages or tracebacks: third-party errors can
            # contain request payloads, endpoints, or credential-adjacent details.
            logger.error("Unexpected worker loop failure (%s).", type(error).__name__)
            stop_event.wait(1.0)
    logger.info("Durable SQS inference worker stopped cleanly.")


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
    if settings.job_backend == "aws":
        config = Config(
            connect_timeout=5,
            read_timeout=max(25, settings.sqs_wait_time_seconds + 5),
            retries={"max_attempts": 3, "mode": "standard"},
        )
        dynamodb = boto3.client(
            "dynamodb", region_name=settings.aws_region, config=config
        )
        sqs = boto3.client("sqs", region_name=settings.aws_region, config=config)
        repository = DynamoDBJobRepository(
            dynamodb, settings.job_table_name or ""
        )
        queue = SQSJobQueue(sqs, settings.inference_queue_url or "")
        processor = DurableJobProcessor(
            repository,
            queue,
            BedrockProvider(settings),
            settings.job_max_receive_count,
        )
        run_durable_worker(
            stop_event,
            settings.heartbeat_path,
            settings.heartbeat_interval_seconds,
            settings.sqs_wait_time_seconds,
            queue,
            processor,
        )
        return
    run_worker(
        stop_event,
        settings.heartbeat_path,
        settings.heartbeat_interval_seconds,
        poll_interval_seconds=settings.poll_interval_seconds,
    )


if __name__ == "__main__":
    main()
