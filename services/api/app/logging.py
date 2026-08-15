import json
import logging
from contextvars import ContextVar, Token
from datetime import UTC, datetime
from typing import Any

_request_id: ContextVar[str] = ContextVar("request_id", default="-")


def bind_request_id(request_id: str) -> Token[str]:
    """Bind a request ID to the current asynchronous execution context."""

    return _request_id.set(request_id)


def reset_request_id(token: Token[str]) -> None:
    """Restore the previous request context after a request completes."""

    _request_id.reset(token)


def current_request_id() -> str:
    return _request_id.get()


class JsonFormatter(logging.Formatter):
    """Emit one machine-readable JSON object per log record."""

    structured_fields = (
        "event",
        "method",
        "route",
        "status_code",
        "latency_ms",
        "model",
        "error_type",
    )

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "request_id": current_request_id(),
        }
        for field in self.structured_fields:
            if hasattr(record, field):
                payload[field] = getattr(record, field)

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def configure_logging(log_level: str) -> None:
    """Configure the application logger without modifying global libraries."""

    level = logging.getLevelNamesMapping().get(log_level.upper())
    if not isinstance(level, int):
        raise TypeError(f"Unsupported log level: {log_level}")

    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())

    app_logger = logging.getLogger("app")
    app_logger.handlers.clear()
    app_logger.addHandler(handler)
    app_logger.setLevel(level)
    app_logger.propagate = False
