import io
import json
from pathlib import Path
from unittest.mock import patch

import pytest

from evals.run_remote_eval import remote_predictor, run_cli, validate_base_url


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def test_remote_predictor_posts_prompt_and_maps_usage():
    response = FakeResponse(
        json.dumps(
            {
                "output": "AWS",
                "model": "test-model",
                "latency_ms": 20,
                "input_tokens": 5,
                "output_tokens": 1,
                "estimated_cost": 0.00001,
            }
        ).encode()
    )
    with patch("evals.run_remote_eval.urlopen", return_value=response) as mocked:
        prediction = remote_predictor("https://staging.example.com", "a" * 32)("prompt")

    request = mocked.call_args.args[0]
    assert request.full_url == "https://staging.example.com/v1/generate"
    assert json.loads(request.data) == {"prompt": "prompt"}
    assert prediction.output == "AWS"
    request = mocked.call_args.args[0]
    assert request.get_header("X-api-key") == "a" * 32
    assert prediction.estimated_cost_usd == 0.00001


@pytest.mark.parametrize(
    "value",
    [
        "http://staging.example.com",
        "https://user@staging.example.com",
        "https://staging.example.com/api",
        "https://staging.example.com?debug=1",
    ],
)
def test_remote_evaluation_rejects_unsafe_origins(value):
    with pytest.raises(ValueError, match="HTTPS origin"):
        validate_base_url(value)


def test_remote_cli_fails_quality_regression(tmp_path: Path):
    dataset = tmp_path / "dataset.json"
    dataset.write_text(
        json.dumps([{"id": "one", "prompt": "prompt", "expected_output": "EXPECTED"}]),
        encoding="utf-8",
    )
    payload = json.dumps({"output": "REGRESSED", "model": "model", "estimated_cost": 0}).encode()
    with patch("evals.run_remote_eval.urlopen", return_value=FakeResponse(payload)):
        assert run_cli("https://staging.example.com", dataset, "a" * 32) == 1


def test_remote_predictor_rejects_missing_or_weak_authentication():
    with pytest.raises(ValueError, match="32-128 URL-safe"):
        remote_predictor("https://staging.example.com", "short")
