from typing import Protocol, runtime_checkable


@runtime_checkable
class LLMProvider(Protocol):
    """Contract implemented by every model backend."""

    def generate(self, prompt: str) -> str:
        """Generate a text response for a validated prompt."""

        ...

