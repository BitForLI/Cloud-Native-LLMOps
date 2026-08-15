import pytest
from app.config import Settings
from app.providers.base import LLMProvider
from app.providers.bedrock import BedrockProvider
from app.providers.factory import create_provider
from app.providers.local import LocalProvider


def test_local_provider_is_deterministic():
    provider = LocalProvider()

    assert isinstance(provider, LLMProvider)
    assert provider.generate("  hello  ") == "Received: hello"


def test_factory_selects_local_provider():
    settings = Settings(llm_provider="local", _env_file=None)

    provider = create_provider(settings)

    assert isinstance(provider, LocalProvider)


def test_factory_selects_bedrock_provider_with_configuration():
    settings = Settings(
        llm_provider="bedrock",
        aws_region="us-east-1",
        bedrock_model_id="example-model",
        _env_file=None,
    )

    provider = create_provider(settings)

    assert isinstance(provider, BedrockProvider)
    assert isinstance(provider, LLMProvider)
    assert provider.region == "us-east-1"
    assert provider.model_id == "example-model"


def test_bedrock_provider_fails_clearly_before_step_three():
    settings = Settings(llm_provider="bedrock", _env_file=None)
    provider = BedrockProvider(settings)

    with pytest.raises(NotImplementedError, match="integration step 3"):
        provider.generate("hello")
