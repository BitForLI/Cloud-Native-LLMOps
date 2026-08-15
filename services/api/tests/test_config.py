import pytest
from app.config import Settings
from pydantic import ValidationError


def test_settings_have_safe_local_defaults():
    settings = Settings(_env_file=None)

    assert settings.app_env == "local"
    assert settings.api_auth_token is None
    assert settings.aws_region == "ap-southeast-2"
    assert settings.llm_provider == "local"
    assert settings.job_backend == "memory"
    assert settings.bedrock_model_id == "anthropic.claude-3-haiku-20240307-v1:0"
    assert settings.bedrock_max_tokens == 512
    assert settings.bedrock_temperature == 0.0
    assert settings.bedrock_connect_timeout_seconds == 5
    assert settings.bedrock_read_timeout_seconds == 60
    assert settings.log_level == "INFO"


def test_settings_read_environment_variables(monkeypatch):
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("API_AUTH_TOKEN", "s" * 32)
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4317")
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("LLM_PROVIDER", "bedrock")
    monkeypatch.setenv("BEDROCK_MODEL_ID", "example-model")
    monkeypatch.setenv("BEDROCK_MAX_TOKENS", "1024")
    monkeypatch.setenv("BEDROCK_TEMPERATURE", "0.25")
    monkeypatch.setenv("BEDROCK_INPUT_COST_PER_MILLION_TOKENS", "0.5")
    monkeypatch.setenv("BEDROCK_OUTPUT_COST_PER_MILLION_TOKENS", "1.5")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")

    settings = Settings(_env_file=None)

    assert settings.app_env == "staging"
    assert settings.api_auth_token.get_secret_value() == "s" * 32
    assert settings.otel_exporter_otlp_endpoint == "http://127.0.0.1:4317"
    assert settings.otel_trace_sample_ratio == 0.1
    assert settings.aws_region == "us-east-1"
    assert settings.llm_provider == "bedrock"
    assert settings.bedrock_model_id == "example-model"
    assert settings.bedrock_max_tokens == 1024
    assert settings.bedrock_temperature == 0.25
    assert settings.bedrock_input_cost_per_million_tokens == 0.5
    assert settings.bedrock_output_cost_per_million_tokens == 1.5
    assert settings.log_level == "DEBUG"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("bedrock_max_tokens", 0),
        ("bedrock_temperature", 1.1),
        ("bedrock_input_cost_per_million_tokens", -0.1),
        ("bedrock_output_cost_per_million_tokens", -0.1),
        ("bedrock_connect_timeout_seconds", 0),
        ("bedrock_read_timeout_seconds", 301),
    ],
)
def test_settings_reject_invalid_bedrock_limits(field, value):
    with pytest.raises(ValidationError):
        Settings(**{field: value}, _env_file=None)


def test_settings_reject_unknown_log_level():
    with pytest.raises(ValidationError):
        Settings(log_level="TRACE", _env_file=None)


def test_aws_job_backend_requires_durable_resource_names():
    with pytest.raises(ValidationError, match="JOB_TABLE_NAME"):
        Settings(job_backend="aws", _env_file=None)

    settings = Settings(
        job_backend="aws",
        job_table_name="jobs",
        inference_queue_url="https://sqs.example/jobs",
        _env_file=None,
    )
    assert settings.job_ttl_seconds == 604800


@pytest.mark.parametrize("app_env", ["dev", "staging", "production"])
def test_deployed_environments_require_strong_api_token(app_env):
    with pytest.raises(ValidationError, match="API_AUTH_TOKEN"):
        Settings(app_env=app_env, _env_file=None)

    with pytest.raises(ValidationError):
        Settings(
            app_env=app_env,
            api_auth_token="short",
            otel_exporter_otlp_endpoint="http://127.0.0.1:4317",
            _env_file=None,
        )

    with pytest.raises(ValidationError, match="URL-safe"):
        Settings(
            app_env=app_env,
            api_auth_token="x" * 31 + "\n",
            otel_exporter_otlp_endpoint="http://127.0.0.1:4317",
            _env_file=None,
        )

    settings = Settings(
        app_env=app_env,
        api_auth_token="x" * 32,
        otel_exporter_otlp_endpoint="http://127.0.0.1:4317",
        _env_file=None,
    )
    assert settings.api_auth_token.get_secret_value() == "x" * 32
    assert "api_auth_token" not in settings.dependency_cache_json()
    assert "x" * 32 not in settings.dependency_cache_json()


def test_deployed_environments_reject_missing_or_remote_trace_collector():
    with pytest.raises(ValidationError, match="OTEL_EXPORTER_OTLP_ENDPOINT"):
        Settings(app_env="production", api_auth_token="x" * 32, _env_file=None)

    with pytest.raises(ValidationError, match="ECS-local collector"):
        Settings(
            app_env="production",
            api_auth_token="x" * 32,
            otel_exporter_otlp_endpoint="https://telemetry.example.com:4317",
            _env_file=None,
        )
