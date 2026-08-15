from dataclasses import dataclass
from typing import Protocol, runtime_checkable


@dataclass(frozen=True, slots=True)
class LLMResult:
    output: str
    model_id: str
    input_tokens: int | None = None
    output_tokens: int | None = None
    estimated_cost: float | None = None


@runtime_checkable
class LLMProvider(Protocol):
    """Contract implemented by every model backend."""

    @property
    def model_id(self) -> str:
        """Stable identifier for the model used by this provider."""

        ...

    def generate(self, prompt: str) -> LLMResult:
        """Generate a text response for a validated prompt."""

        ...
