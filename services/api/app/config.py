from functools import lru_cache
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application configuration loaded from environment variables or `.env`."""

    app_env: str = "local"
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
        return self


@lru_cache
def get_settings() -> Settings:
    """Return one immutable-by-convention settings instance per process."""

    return Settings()
