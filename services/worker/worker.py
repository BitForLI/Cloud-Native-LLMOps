import logging
import os
import signal
import time
from pathlib import Path
from threading import Event

logger = logging.getLogger("llmops.worker")


def write_heartbeat(path: Path) -> None:
    """Atomically update the worker heartbeat consumed by its health check."""

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(".tmp")
    temporary_path.write_text(str(time.time()), encoding="utf-8")
    temporary_path.replace(path)


def run_worker(stop_event: Event, heartbeat_path: Path, interval_seconds: float) -> None:
    """Run the worker loop until ECS or Docker requests a graceful stop."""

    if interval_seconds <= 0:
        raise ValueError("Worker heartbeat interval must be positive.")

    logger.info("Worker started; waiting for asynchronous inference jobs.")
    while not stop_event.is_set():
        write_heartbeat(heartbeat_path)
        stop_event.wait(interval_seconds)
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
    stop_event = Event()
    _install_signal_handlers(stop_event)
    heartbeat_path = Path(
        os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/llmops-worker-heartbeat")
    )
    interval_seconds = float(os.getenv("WORKER_HEARTBEAT_INTERVAL_SECONDS", "30"))
    run_worker(stop_event, heartbeat_path, interval_seconds)


if __name__ == "__main__":
    main()
