FROM python:3.13.14-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build
COPY services/api/requirements.txt ./requirements.txt
RUN python -m pip wheel --wheel-dir=/wheels -r requirements.txt

FROM python:3.13.14-slim-bookworm AS runtime

ARG APP_UID=10001
ARG APP_GID=10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app

RUN groupadd --gid "${APP_GID}" app \
    && useradd --uid "${APP_UID}" --gid app --create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /wheels /wheels
COPY services/api/requirements.txt ./requirements.txt
RUN python -m pip install --no-index --no-compile --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels requirements.txt

COPY --chown=app:app services/api/app ./app
COPY --chown=app:app services/__init__.py ./services/__init__.py
COPY --chown=app:app services/worker/__init__.py ./services/worker/__init__.py
COPY --chown=app:app services/worker/app ./services/worker/app

USER app
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; raise SystemExit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
