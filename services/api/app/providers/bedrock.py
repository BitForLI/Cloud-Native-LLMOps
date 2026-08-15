import json
from typing import Any

import boto3
from botocore.client import BaseClient
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

from app.config import Settings
from app.providers.base import LLMProviderError, LLMResult


class BedrockProviderError(LLMProviderError):
    """Base error raised by the Bedrock provider boundary."""


class BedrockInvocationError(BedrockProviderError):
    """Bedrock rejected the request or could not be reached."""


class BedrockResponseError(BedrockProviderError):
    """Bedrock returned a response that did not match the expected schema."""


class BedrockProvider:
    """Invoke Anthropic Claude through the Amazon Bedrock Runtime API."""

    def __init__(
        self,
        settings: Settings,
        client: BaseClient | None = None,
    ) -> None:
        self.region = settings.aws_region
        self.model_id = settings.bedrock_model_id
        self.max_tokens = settings.bedrock_max_tokens
        self.temperature = settings.bedrock_temperature
        self.input_cost_per_million_tokens = (
            settings.bedrock_input_cost_per_million_tokens
        )
        self.output_cost_per_million_tokens = (
            settings.bedrock_output_cost_per_million_tokens
        )
        self._client = client or boto3.client(
            "bedrock-runtime",
            region_name=self.region,
            config=Config(
                connect_timeout=settings.bedrock_connect_timeout_seconds,
                read_timeout=settings.bedrock_read_timeout_seconds,
                retries={"max_attempts": 3, "mode": "standard"},
            ),
        )

    def generate(self, prompt: str) -> LLMResult:
        request_body = json.dumps(self._build_payload(prompt))

        try:
            response = self._client.invoke_model(
                modelId=self.model_id,
                body=request_body,
                accept="application/json",
                contentType="application/json",
            )
            return self._parse_response(response)
        except BedrockProviderError:
            raise
        except ClientError as exc:
            error_code = exc.response.get("Error", {}).get("Code", "ClientError")
            raise BedrockInvocationError(
                f"Bedrock invocation failed for model {self.model_id}: {error_code}"
            ) from exc
        except BotoCoreError as exc:
            raise BedrockInvocationError(
                f"Bedrock runtime is unavailable for model {self.model_id}: "
                f"{type(exc).__name__}"
            ) from exc

    def _build_payload(self, prompt: str) -> dict[str, Any]:
        """Build the native Anthropic Messages API payload used by Bedrock."""

        normalized_prompt = prompt.strip()
        if not normalized_prompt:
            raise ValueError("Prompt must not be empty.")

        return {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "messages": [
                {
                    "role": "user",
                    "content": [{"type": "text", "text": normalized_prompt}],
                }
            ],
        }

    def _parse_response(self, response: dict[str, Any]) -> LLMResult:
        """Extract all text blocks from an Anthropic Messages API response."""

        body = response.get("body")
        if body is None or not hasattr(body, "read"):
            raise BedrockResponseError("Bedrock response is missing a readable body.")

        try:
            raw_body = body.read()
            if isinstance(raw_body, bytes):
                raw_body = raw_body.decode("utf-8")
            payload = json.loads(raw_body)
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc:
            raise BedrockResponseError("Bedrock returned invalid JSON.") from exc

        content = payload.get("content")
        if not isinstance(content, list):
            raise BedrockResponseError("Bedrock response is missing content blocks.")

        text = "".join(
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        ).strip()
        if not text:
            raise BedrockResponseError("Bedrock response contains no generated text.")

        input_tokens, output_tokens = self._parse_usage(payload)
        return LLMResult(
            output=text,
            model_id=self.model_id,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            estimated_cost=self._estimate_cost(input_tokens, output_tokens),
        )

    def _parse_usage(self, payload: dict[str, Any]) -> tuple[int | None, int | None]:
        usage = payload.get("usage")
        if usage is None:
            return None, None
        if not isinstance(usage, dict):
            raise BedrockResponseError("Bedrock response contains invalid usage data.")

        input_tokens = usage.get("input_tokens")
        output_tokens = usage.get("output_tokens")
        for token_count in (input_tokens, output_tokens):
            if token_count is not None and (
                not isinstance(token_count, int)
                or isinstance(token_count, bool)
                or token_count < 0
            ):
                raise BedrockResponseError(
                    "Bedrock response contains invalid token counts."
                )
        return input_tokens, output_tokens

    def _estimate_cost(
        self,
        input_tokens: int | None,
        output_tokens: int | None,
    ) -> float | None:
        if (
            input_tokens is None
            or output_tokens is None
            or self.input_cost_per_million_tokens is None
            or self.output_cost_per_million_tokens is None
        ):
            return None

        cost = (
            input_tokens * self.input_cost_per_million_tokens
            + output_tokens * self.output_cost_per_million_tokens
        ) / 1_000_000
        return round(cost, 8)
