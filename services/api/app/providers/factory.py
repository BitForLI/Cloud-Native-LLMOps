from functools import lru_cache
from typing import Annotated

from fastapi import Depends

from app.config import Settings, get_settings
from app.providers.base import LLMProvider
from app.providers.bedrock import BedrockProvider
from app.providers.local import LocalProvider


def create_provider(settings: Settings) -> LLMProvider:
    """Build a provider from explicit settings for tests and composition."""

    if settings.llm_provider == "local":
        return LocalProvider()
    if settings.llm_provider == "bedrock":
        return BedrockProvider(settings)
    raise ValueError(f"Unsupported LLM provider: {settings.llm_provider}")


def get_provider(
    settings: Annotated[Settings, Depends(get_settings)],
) -> LLMProvider:
    """Return a cached provider so boto3 clients are reused across requests."""

    return _get_cached_provider(settings.dependency_cache_json())


@lru_cache(maxsize=8)
def _get_cached_provider(serialized_settings: str) -> LLMProvider:
    return create_provider(Settings.model_validate_json(serialized_settings))


def clear_provider_cache() -> None:
    """Clear cached providers during tests or an in-process config reload."""

    _get_cached_provider.cache_clear()
