import io
import json
import logging

import pytest
from app.logging import (
    JsonFormatter,
    bind_request_id,
    configure_logging,
    reset_request_id,
)


def test_json_formatter_emits_structured_request_fields():
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(JsonFormatter())
    test_logger = logging.getLogger("test.structured")
    test_logger.handlers = [handler]
    test_logger.setLevel(logging.INFO)
    test_logger.propagate = False
    token = bind_request_id("req-123")

    try:
        test_logger.info(
            "Request completed",
            extra={
                "event": "http_request_completed",
                "method": "POST",
                "route": "/v1/generate",
                "status_code": 200,
                "latency_ms": 12.5,
                "model": "test-model",
                "error_type": None,
            },
        )
    finally:
        reset_request_id(token)

    payload = json.loads(stream.getvalue())
    assert payload["request_id"] == "req-123"
    assert payload["route"] == "/v1/generate"
    assert payload["status_code"] == 200
    assert payload["latency_ms"] == 12.5
    assert payload["model"] == "test-model"
    assert payload["error_type"] is None
    assert payload["timestamp"].endswith("+00:00")


def test_configure_logging_is_idempotent():
    configure_logging("DEBUG")
    configure_logging("INFO")

    app_logger = logging.getLogger("app")
    assert app_logger.level == logging.INFO
    assert len(app_logger.handlers) == 1
    assert isinstance(app_logger.handlers[0].formatter, JsonFormatter)


def test_configure_logging_rejects_unknown_level():
    with pytest.raises(TypeError, match="Unsupported log level"):
        configure_logging("TRACE")
