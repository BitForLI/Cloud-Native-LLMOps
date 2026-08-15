import json

import pytest
from app.config import Settings
from app.providers.bedrock import (
    BedrockInvocationError,
    BedrockProvider,
    BedrockResponseError,
)
from botocore.exceptions import ClientError, EndpointConnectionError


class FakeBody:
    def __init__(self, payload):
        self.payload = payload

    def read(self):
        return self.payload


class FakeClient:
    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.calls = []

    def invoke_model(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error
        return self.response


def make_settings(**overrides):
    values = {
        "llm_provider": "bedrock",
        "aws_region": "us-east-1",
        "bedrock_model_id": "anthropic.test-model",
        "bedrock_max_tokens": 256,
        "bedrock_temperature": 0.2,
    }
    values.update(overrides)
    return Settings(**values, _env_file=None)


def test_provider_creates_bedrock_runtime_client_with_safe_timeouts(monkeypatch):
    captured = {}
    fake_client = FakeClient()

    def fake_boto3_client(service_name, **kwargs):
        captured["service_name"] = service_name
        captured.update(kwargs)
        return fake_client

    monkeypatch.setattr("app.providers.bedrock.boto3.client", fake_boto3_client)

    provider = BedrockProvider(make_settings())

    assert provider._client is fake_client
    assert captured["service_name"] == "bedrock-runtime"
    assert captured["region_name"] == "us-east-1"
    assert captured["config"].connect_timeout == 5
    assert captured["config"].read_timeout == 60
    assert captured["config"].retries["mode"] == "standard"


def test_build_payload_uses_anthropic_messages_schema():
    provider = BedrockProvider(make_settings(), client=FakeClient())

    payload = provider._build_payload("  Explain LLMOps  ")

    assert payload == {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 256,
        "temperature": 0.2,
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": "Explain LLMOps"}],
            }
        ],
    }


def test_generate_invokes_model_and_combines_text_blocks():
    response = {
        "body": FakeBody(
            json.dumps(
                {
                    "content": [
                        {"type": "text", "text": "Cloud-native "},
                        {"type": "tool_use", "name": "ignored"},
                        {"type": "text", "text": "LLMOps"},
                    ]
                }
            ).encode("utf-8")
        )
    }
    client = FakeClient(response=response)
    provider = BedrockProvider(make_settings(), client=client)

    result = provider.generate("Explain LLMOps")

    assert result == "Cloud-native LLMOps"
    assert len(client.calls) == 1
    request = client.calls[0]
    assert request["modelId"] == "anthropic.test-model"
    assert request["accept"] == "application/json"
    assert request["contentType"] == "application/json"
    assert json.loads(request["body"])["messages"][0]["role"] == "user"


def test_generate_rejects_blank_prompt_before_invocation():
    client = FakeClient()
    provider = BedrockProvider(make_settings(), client=client)

    with pytest.raises(ValueError, match="must not be empty"):
        provider.generate("   ")

    assert client.calls == []


def test_client_error_is_converted_without_exposing_aws_message():
    error = ClientError(
        {"Error": {"Code": "AccessDeniedException", "Message": "secret detail"}},
        "InvokeModel",
    )
    provider = BedrockProvider(make_settings(), client=FakeClient(error=error))

    with pytest.raises(BedrockInvocationError, match="AccessDeniedException") as exc:
        provider.generate("hello")

    assert "secret detail" not in str(exc.value)
    assert exc.value.__cause__ is error


def test_transport_error_is_converted():
    error = EndpointConnectionError(endpoint_url="https://bedrock.example")
    provider = BedrockProvider(make_settings(), client=FakeClient(error=error))

    with pytest.raises(BedrockInvocationError, match="EndpointConnectionError"):
        provider.generate("hello")


@pytest.mark.parametrize(
    ("response", "message"),
    [
        ({}, "readable body"),
        ({"body": FakeBody(b"not-json")}, "invalid JSON"),
        ({"body": FakeBody(b"{}")}, "missing content"),
        (
            {"body": FakeBody(b'{"content":[{"type":"text","text":""}]}')},
            "no generated text",
        ),
    ],
)
def test_malformed_responses_raise_domain_error(response, message):
    provider = BedrockProvider(make_settings(), client=FakeClient(response=response))

    with pytest.raises(BedrockResponseError, match=message):
        provider.generate("hello")
