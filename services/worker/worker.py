"""Compatibility entry point for the packaged worker runtime."""

from services.worker.app.worker import main, run_worker, write_heartbeat

__all__ = ["main", "run_worker", "write_heartbeat"]


if __name__ == "__main__":
    main()
