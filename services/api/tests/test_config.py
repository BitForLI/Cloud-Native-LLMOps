import pytest
from app.config import Settings
from pydantic import ValidationError


def test_settings_have_safe_local_defaults():
    settings = Settings(_env_file=None)

    assert settings.app_env == "local"
    assert settings.aws_region == "ap-southeast-2"
    assert settings.llm_provider == "local"
    assert settings.bedrock_model_id == "anthropic.claude-3-haiku-20240307-v1:0"
    assert settings.bedrock_max_tokens == 512
    assert settings.bedrock_temperature == 0.0
    assert settings.bedrock_connect_timeout_seconds == 5
    assert settings.bedrock_read_timeout_seconds == 60
    assert settings.log_level == "INFO"


def test_settings_read_environment_variables(monkeypatch):
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("LLM_PROVIDER", "bedrock")
    monkeypatch.setenv("BEDROCK_MODEL_ID", "example-model")
    monkeypatch.setenv("BEDROCK_MAX_TOKENS", "1024")
    monkeypatch.setenv("BEDROCK_TEMPERATURE", "0.25")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")

    settings = Settings(_env_file=None)

    assert settings.app_env == "staging"
    assert settings.aws_region == "us-east-1"
    assert settings.llm_provider == "bedrock"
    assert settings.bedrock_model_id == "example-model"
    assert settings.bedrock_max_tokens == 1024
    assert settings.bedrock_temperature == 0.25
    assert settings.log_level == "DEBUG"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("bedrock_max_tokens", 0),
        ("bedrock_temperature", 1.1),
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
