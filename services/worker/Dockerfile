FROM python:3.13.14-slim-bookworm AS runtime

ARG APP_UID=10001
ARG APP_GID=10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WORKER_HEARTBEAT_PATH=/tmp/llmops-worker-heartbeat \
    WORKER_HEARTBEAT_INTERVAL_SECONDS=30 \
    WORKER_HEARTBEAT_MAX_AGE_SECONDS=90

RUN groupadd --gid "${APP_GID}" app \
    && useradd --uid "${APP_UID}" --gid app --create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --chown=app:app services/worker/worker.py services/worker/healthcheck.py ./

USER app

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "healthcheck.py"]

CMD ["python", "worker.py"]
