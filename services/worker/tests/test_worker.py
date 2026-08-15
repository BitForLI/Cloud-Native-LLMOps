import os
import time
from pathlib import Path

import pytest

from services.worker.healthcheck import is_heartbeat_healthy
from services.worker.worker import run_worker, write_heartbeat


class StopAfterFirstWait:
    def __init__(self):
        self.stopped = False
        self.wait_calls = []

    def is_set(self):
        return self.stopped

    def wait(self, timeout):
        self.wait_calls.append(timeout)
        self.stopped = True
        return True


def test_write_heartbeat_creates_healthy_file(tmp_path):
    heartbeat = tmp_path / "worker-heartbeat"

    write_heartbeat(heartbeat)

    assert heartbeat.is_file()
    assert is_heartbeat_healthy(heartbeat, max_age_seconds=5)


def test_stale_or_missing_heartbeat_is_unhealthy(tmp_path):
    missing = tmp_path / "missing"
    stale = tmp_path / "stale"
    stale.write_text("old", encoding="utf-8")
    old_timestamp = time.time() - 120
    os.utime(stale, (old_timestamp, old_timestamp))

    assert not is_heartbeat_healthy(missing, max_age_seconds=90)
    assert not is_heartbeat_healthy(stale, max_age_seconds=90)


def test_worker_updates_heartbeat_and_stops_gracefully(tmp_path):
    heartbeat = tmp_path / "worker-heartbeat"
    stop_event = StopAfterFirstWait()

    run_worker(stop_event, heartbeat, interval_seconds=0.01)

    assert heartbeat.is_file()
    assert stop_event.wait_calls == [0.01]


@pytest.mark.parametrize("interval", [0, -1])
def test_worker_rejects_invalid_heartbeat_interval(interval):
    with pytest.raises(ValueError, match="must be positive"):
        run_worker(StopAfterFirstWait(), Path("unused"), interval)
