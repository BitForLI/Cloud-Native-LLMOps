"""Evaluate the deployed staging inference API before artifact promotion passes."""

import argparse
import json
from collections.abc import Callable, Sequence
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from evals.config import EvalConfig
from evals.models import Prediction
from evals.run_eval import load_dataset, run_evaluation

REMOTE_DATASET = Path(__file__).with_name("remote_dataset.json")


def validate_base_url(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        raise ValueError("base URL must be an HTTPS origin without credentials or a path")
    return value.rstrip("/")


def remote_predictor(
    base_url: str, timeout_seconds: float = 15.0
) -> Callable[[str], Prediction]:
    origin = validate_base_url(base_url)

    def predict(prompt: str) -> Prediction:
        request = Request(
            f"{origin}/v1/generate",
            data=json.dumps({"prompt": prompt}).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "llmops-staging-eval/1"},
            method="POST",
        )
        with urlopen(request, timeout=timeout_seconds) as response:
            payload = json.load(response)
        if not isinstance(payload, dict):
            raise TypeError("remote inference response must be an object")
        if not isinstance(payload.get("output"), str):
            raise TypeError("remote inference output must be text")
        if not isinstance(payload.get("model"), str):
            raise TypeError("remote inference model must be text")
        if not payload["model"]:
            raise ValueError("remote inference model must not be empty")
        cost = payload.get("estimated_cost")
        if cost is not None and (not isinstance(cost, (int, float)) or cost < 0):
            raise ValueError("remote inference response has an invalid cost")
        return Prediction(
            output=payload["output"],
            input_tokens=payload.get("input_tokens"),
            output_tokens=payload.get("output_tokens"),
            estimated_cost_usd=float(cost) if cost is not None else None,
        )

    return predict


def run_cli(base_url: str, dataset_path: Path = REMOTE_DATASET) -> int:
    cases = load_dataset(dataset_path)
    _, report = run_evaluation(
        cases,
        predictor=remote_predictor(base_url),
        config=EvalConfig.from_env(),
    )
    print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    return 0 if report.overall_status == "PASS" else 1


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="HTTPS staging API origin")
    parser.add_argument("--dataset", type=Path, default=REMOTE_DATASET)
    args = parser.parse_args(argv)
    raise SystemExit(run_cli(args.base_url, args.dataset))


if __name__ == "__main__":
    main()
