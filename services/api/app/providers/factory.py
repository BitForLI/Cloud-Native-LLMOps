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
    """FastAPI dependency that selects the configured model provider."""

    return create_provider(settings)
