from typing import Protocol, runtime_checkable


@runtime_checkable
class LLMProvider(Protocol):
    """Contract implemented by every model backend."""

    @property
    def model_id(self) -> str:
        """Stable identifier for the model used by this provider."""

        ...

    def generate(self, prompt: str) -> str:
        """Generate a text response for a validated prompt."""

        ...
