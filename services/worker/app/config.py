import os
from dataclasses import dataclass
from pathlib import Path


def _positive_int(name: str, default: int) -> int:
    raw_value = os.getenv(name, str(default))
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if value < 1:
        raise ValueError(f"{name} must be positive")
    return value


def _positive_float(name: str, default: float) -> float:
    raw_value = os.getenv(name, str(default))
    try:
        value = float(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number") from exc
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


@dataclass(frozen=True, slots=True)
class WorkerSettings:
    """Validated settings shared by the local executor and worker container."""

    max_workers: int = 2
    max_pending_jobs: int = 100
    max_stored_jobs: int = 1000
    poll_interval_seconds: float = 0.25
    heartbeat_path: Path = Path("/tmp/llmops-worker-heartbeat")
    heartbeat_interval_seconds: float = 30.0

    def __post_init__(self) -> None:
        if self.max_workers < 1:
            raise ValueError("max_workers must be positive")
        if self.max_pending_jobs < 1:
            raise ValueError("max_pending_jobs must be positive")
        if self.max_stored_jobs < self.max_pending_jobs:
            raise ValueError("max_stored_jobs must be at least max_pending_jobs")
        if self.poll_interval_seconds <= 0:
            raise ValueError("poll_interval_seconds must be positive")
        if self.heartbeat_interval_seconds <= 0:
            raise ValueError("heartbeat_interval_seconds must be positive")

    @classmethod
    def from_env(cls) -> "WorkerSettings":
        return cls(
            max_workers=_positive_int("JOB_MAX_WORKERS", 2),
            max_pending_jobs=_positive_int("JOB_MAX_PENDING", 100),
            max_stored_jobs=_positive_int("JOB_MAX_STORED", 1000),
            poll_interval_seconds=_positive_float("JOB_POLL_INTERVAL_SECONDS", 0.25),
            heartbeat_path=Path(
                os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/llmops-worker-heartbeat")
            ),
            heartbeat_interval_seconds=_positive_float(
                "WORKER_HEARTBEAT_INTERVAL_SECONDS", 30.0
            ),
        )
