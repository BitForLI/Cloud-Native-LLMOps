class LocalProvider:
    """Deterministic provider used for local development and CI."""

    def generate(self, prompt: str) -> str:
        return f"Received: {prompt.strip()}"

