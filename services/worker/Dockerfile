FROM python:3.13.14-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build
COPY services/worker/requirements.txt ./requirements.txt
RUN python -m pip wheel --wheel-dir=/wheels -r requirements.txt

FROM python:3.13.14-slim-bookworm AS runtime

ARG APP_UID=10001
ARG APP_GID=10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    JOB_MAX_WORKERS=2 \
    JOB_MAX_PENDING=100 \
    JOB_MAX_STORED=1000 \
    JOB_POLL_INTERVAL_SECONDS=0.25 \
    WORKER_HEARTBEAT_PATH=/tmp/llmops-worker-heartbeat \
    WORKER_HEARTBEAT_INTERVAL_SECONDS=30 \
    WORKER_HEARTBEAT_MAX_AGE_SECONDS=90

RUN groupadd --gid "${APP_GID}" app \
    && useradd --uid "${APP_UID}" --gid app --create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /wheels /wheels
COPY services/worker/requirements.txt ./requirements.txt
RUN python -m pip install --no-index --no-compile --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels requirements.txt

COPY --chown=app:app services/__init__.py ./services/__init__.py
COPY --chown=app:app services/common ./services/common
COPY --chown=app:app services/worker ./services/worker

USER app

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-m", "services.worker.healthcheck"]

CMD ["python", "-m", "services.worker.app.worker"]
