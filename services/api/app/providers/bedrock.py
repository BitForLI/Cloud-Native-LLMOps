from app.config import Settings


class BedrockProvider:
    """Amazon Bedrock provider boundary.

    The boto3 runtime invocation is intentionally added in step 3. Keeping the
    provider class in place now lets the API and factory remain unchanged when
    the AWS implementation is introduced.
    """

    def __init__(self, settings: Settings) -> None:
        self.region = settings.aws_region
        self.model_id = settings.bedrock_model_id

    def generate(self, prompt: str) -> str:
        raise NotImplementedError(
            "Amazon Bedrock invocation is not available until integration step 3."
        )

