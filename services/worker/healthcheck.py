import os
import time
from pathlib import Path


def is_heartbeat_healthy(path: Path, max_age_seconds: float) -> bool:
    if max_age_seconds <= 0 or not path.is_file():
        return False
    try:
        age_seconds = time.time() - path.stat().st_mtime
    except OSError:
        return False
    return 0 <= age_seconds <= max_age_seconds


def main() -> None:
    heartbeat_path = Path(
        os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/llmops-worker-heartbeat")
    )
    max_age_seconds = float(os.getenv("WORKER_HEARTBEAT_MAX_AGE_SECONDS", "90"))
    raise SystemExit(
        0 if is_heartbeat_healthy(heartbeat_path, max_age_seconds) else 1
    )


if __name__ == "__main__":
    main()

