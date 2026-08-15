from app.providers.base import LLMResult


class LocalProvider:
    """Deterministic provider used for local development and CI."""

    model_id = "local-deterministic-stub"

    def generate(self, prompt: str) -> LLMResult:
        return LLMResult(
            output=f"Received: {prompt.strip()}",
            model_id=self.model_id,
            estimated_cost=0.0,
        )
