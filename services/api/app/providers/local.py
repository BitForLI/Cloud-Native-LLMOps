class LocalProvider:
    """Deterministic provider used for local development and CI."""

    model_id = "local-deterministic-stub"

    def generate(self, prompt: str) -> str:
        return f"Received: {prompt.strip()}"
