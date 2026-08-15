import logging
import re
import time
from uuid import uuid4

from fastapi import Request, Response

from app.logging import bind_request_id, reset_request_id

REQUEST_ID_HEADER = "X-Request-ID"
_VALID_REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
logger = logging.getLogger("app.request")


def _request_id_from(request: Request) -> str:
    supplied = request.headers.get(REQUEST_ID_HEADER, "").strip()
    if _VALID_REQUEST_ID.fullmatch(supplied):
        return supplied
    return str(uuid4())


def _route_for(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", request.url.path)


def _log_fields(
    request: Request,
    status_code: int,
    latency_ms: float,
    error_type: str | None,
) -> dict[str, object]:
    return {
        "event": "http_request_completed",
        "method": request.method,
        "route": _route_for(request),
        "status_code": status_code,
        "latency_ms": latency_ms,
        "model": getattr(request.state, "model_id", None),
        "error_type": error_type,
    }


async def request_context_middleware(request: Request, call_next) -> Response:
    """Attach request context and emit one completion log for every request."""

    request_id = _request_id_from(request)
    token = bind_request_id(request_id)
    request.state.request_id = request_id
    started = time.perf_counter()

    try:
        response = await call_next(request)
    except Exception as exc:
        latency_ms = round((time.perf_counter() - started) * 1000, 2)
        logger.exception(
            "Request failed",
            extra=_log_fields(request, 500, latency_ms, type(exc).__name__),
        )
        raise
    else:
        latency_ms = round((time.perf_counter() - started) * 1000, 2)
        response.headers[REQUEST_ID_HEADER] = request_id
        logger.info(
            "Request completed",
            extra=_log_fields(request, response.status_code, latency_ms, None),
        )
        return response
    finally:
        reset_request_id(token)

