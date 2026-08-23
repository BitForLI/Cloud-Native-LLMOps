from app.config import Settings
from app.providers.base import LLMProvider
from app.providers.bedrock import BedrockProvider
from app.providers.factory import clear_provider_cache, create_provider, get_provider
from app.providers.local import LocalProvider

from services.common.llm.base import LLMProvider as SharedLLMProvider
from services.common.llm.bedrock import BedrockProvider as SharedBedrockProvider
from services.common.llm.local import LocalProvider as SharedLocalProvider


def test_api_provider_exports_use_shared_implementations():
    assert LLMProvider is SharedLLMProvider
    assert BedrockProvider is SharedBedrockProvider
    assert LocalProvider is SharedLocalProvider


def test_local_provider_is_deterministic():
    provider = LocalProvider()

    assert isinstance(provider, LLMProvider)
    assert provider.model_id == "local-deterministic-stub"
    result = provider.generate("  hello  ")
    assert result.output == "Received: hello"
    assert result.model_id == "local-deterministic-stub"
    assert result.input_tokens is None
    assert result.output_tokens is None
    assert result.estimated_cost == 0.0


def test_factory_selects_local_provider():
    settings = Settings(llm_provider="local", _env_file=None)

    provider = create_provider(settings)

    assert isinstance(provider, LocalProvider)


def test_factory_selects_bedrock_provider_with_configuration(monkeypatch):
    fake_client = object()
    monkeypatch.setattr(
        "services.common.llm.bedrock.boto3.client",
        lambda *args, **kwargs: fake_client,
    )
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


def test_fastapi_dependency_reuses_provider_instances():
    clear_provider_cache()
    settings = Settings(llm_provider="local", _env_file=None)

    first = get_provider(settings)
    second = get_provider(settings)

    assert first is second
