import re
from functools import lru_cache
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application configuration loaded from environment variables or `.env`."""

    app_env: str = "local"
    api_auth_token: SecretStr | None = Field(
        default=None, min_length=32, max_length=128
    )
    aws_region: str = "ap-southeast-2"
    llm_provider: Literal["local", "bedrock"] = "local"
    job_backend: Literal["memory", "aws"] = "memory"
    job_table_name: str | None = None
    inference_queue_url: str | None = None
    job_ttl_seconds: int = Field(default=604800, ge=3600, le=31536000)
    bedrock_model_id: str = "anthropic.claude-3-haiku-20240307-v1:0"
    bedrock_max_tokens: int = Field(default=512, ge=1, le=8192)
    bedrock_temperature: float = Field(default=0.0, ge=0.0, le=1.0)
    bedrock_input_cost_per_million_tokens: float | None = Field(default=None, ge=0)
    bedrock_output_cost_per_million_tokens: float | None = Field(default=None, ge=0)
    bedrock_connect_timeout_seconds: int = Field(default=5, ge=1, le=60)
    bedrock_read_timeout_seconds: int = Field(default=60, ge=1, le=300)
    otel_exporter_otlp_endpoint: str | None = None
    otel_trace_sample_ratio: float = Field(default=0.1, ge=0, le=1)
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    @model_validator(mode="after")
    def validate_aws_job_backend(self) -> "Settings":
        if self.job_backend == "aws" and (
            not self.job_table_name or not self.inference_queue_url
        ):
            raise ValueError(
                "JOB_TABLE_NAME and INFERENCE_QUEUE_URL are required for JOB_BACKEND=aws"
            )
        if (
            self.app_env.lower() in {"dev", "staging", "production"}
            and self.api_auth_token is None
        ):
            raise ValueError("API_AUTH_TOKEN is required in deployed environments")
        if (
            self.app_env.lower() in {"dev", "staging", "production"}
            and self.otel_exporter_otlp_endpoint is None
        ):
            raise ValueError(
                "OTEL_EXPORTER_OTLP_ENDPOINT is required in deployed environments"
            )
        if self.otel_exporter_otlp_endpoint not in {
            None,
            "http://127.0.0.1:4317",
        }:
            raise ValueError(
                "OTEL_EXPORTER_OTLP_ENDPOINT must target the ECS-local collector"
            )
        if self.api_auth_token is not None and not re.fullmatch(
            r"[A-Za-z0-9_-]{32,128}", self.api_auth_token.get_secret_value()
        ):
            raise ValueError(
                "API_AUTH_TOKEN must be 32-128 URL-safe alphanumeric, underscore, or hyphen characters"
            )
        return self

    def dependency_cache_json(self) -> str:
        """Serialize service settings without authentication material."""

        return self.model_dump_json(exclude={"api_auth_token", "app_env"})


@lru_cache
def get_settings() -> Settings:
    """Return one immutable-by-convention settings instance per process."""

    return Settings()
