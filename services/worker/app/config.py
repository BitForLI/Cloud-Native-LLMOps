import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


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


def _optional_non_negative_float(name: str) -> float | None:
    raw_value = os.getenv(name)
    if raw_value is None or not raw_value.strip():
        return None
    try:
        value = float(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} must be a number") from exc
    if value < 0:
        raise ValueError(f"{name} must not be negative")
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
    app_env: str = "local"
    job_backend: Literal["memory", "aws"] = "memory"
    aws_region: str = "ap-southeast-2"
    job_table_name: str | None = None
    inference_queue_url: str | None = None
    job_max_receive_count: int = 5
    sqs_wait_time_seconds: int = 20
    bedrock_model_id: str = "anthropic.claude-3-haiku-20240307-v1:0"
    bedrock_max_tokens: int = 512
    bedrock_temperature: float = 0.0
    bedrock_input_cost_per_million_tokens: float | None = None
    bedrock_output_cost_per_million_tokens: float | None = None
    bedrock_connect_timeout_seconds: int = 5
    bedrock_read_timeout_seconds: int = 60
    otel_exporter_otlp_endpoint: str | None = None
    otel_trace_sample_ratio: float = 0.1

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
        if self.job_backend not in {"memory", "aws"}:
            raise ValueError("job_backend must be memory or aws")
        if not self.app_env.strip():
            raise ValueError("app_env must not be empty")
        if self.job_backend == "aws" and (
            not self.job_table_name or not self.inference_queue_url
        ):
            raise ValueError(
                "JOB_TABLE_NAME and INFERENCE_QUEUE_URL are required for JOB_BACKEND=aws"
            )
        if self.job_backend == "aws" and self.otel_exporter_otlp_endpoint is None:
            raise ValueError(
                "OTEL_EXPORTER_OTLP_ENDPOINT is required for JOB_BACKEND=aws"
            )
        if self.otel_exporter_otlp_endpoint not in {
            None,
            "http://127.0.0.1:4317",
        }:
            raise ValueError(
                "OTEL_EXPORTER_OTLP_ENDPOINT must target the ECS-local collector"
            )
        if not 0 <= self.otel_trace_sample_ratio <= 1:
            raise ValueError("otel_trace_sample_ratio must be between 0 and 1")
        if not 0 <= self.sqs_wait_time_seconds <= 20:
            raise ValueError("sqs_wait_time_seconds must be between 0 and 20")
        if not 0 <= self.bedrock_temperature <= 1:
            raise ValueError("bedrock_temperature must be between 0 and 1")

    @classmethod
    def from_env(cls) -> "WorkerSettings":
        backend = os.getenv("JOB_BACKEND", "memory").lower()
        if backend not in {"memory", "aws"}:
            raise ValueError("JOB_BACKEND must be memory or aws")
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
            app_env=os.getenv("APP_ENV", "local"),
            job_backend=backend,
            aws_region=os.getenv("AWS_REGION", "ap-southeast-2"),
            job_table_name=os.getenv("JOB_TABLE_NAME"),
            inference_queue_url=os.getenv("INFERENCE_QUEUE_URL"),
            job_max_receive_count=_positive_int("JOB_MAX_RECEIVE_COUNT", 5),
            sqs_wait_time_seconds=int(os.getenv("SQS_WAIT_TIME_SECONDS", "20")),
            bedrock_model_id=os.getenv(
                "BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0"
            ),
            bedrock_max_tokens=_positive_int("BEDROCK_MAX_TOKENS", 512),
            bedrock_temperature=float(os.getenv("BEDROCK_TEMPERATURE", "0")),
            bedrock_input_cost_per_million_tokens=_optional_non_negative_float(
                "BEDROCK_INPUT_COST_PER_MILLION_TOKENS"
            ),
            bedrock_output_cost_per_million_tokens=_optional_non_negative_float(
                "BEDROCK_OUTPUT_COST_PER_MILLION_TOKENS"
            ),
            bedrock_connect_timeout_seconds=_positive_int(
                "BEDROCK_CONNECT_TIMEOUT_SECONDS", 5
            ),
            bedrock_read_timeout_seconds=_positive_int(
                "BEDROCK_READ_TIMEOUT_SECONDS", 60
            ),
            otel_exporter_otlp_endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
            otel_trace_sample_ratio=float(os.getenv("OTEL_TRACE_SAMPLE_RATIO", "0.1")),
        )
