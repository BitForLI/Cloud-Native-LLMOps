from app.config import Settings


def test_settings_have_safe_local_defaults():
    settings = Settings(_env_file=None)

    assert settings.app_env == "local"
    assert settings.aws_region == "ap-southeast-2"
    assert settings.bedrock_model_id == "local-deterministic-stub"
    assert settings.log_level == "INFO"


def test_settings_read_environment_variables(monkeypatch):
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("BEDROCK_MODEL_ID", "example-model")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")

    settings = Settings(_env_file=None)

    assert settings.app_env == "staging"
    assert settings.aws_region == "us-east-1"
    assert settings.bedrock_model_id == "example-model"
    assert settings.log_level == "DEBUG"

