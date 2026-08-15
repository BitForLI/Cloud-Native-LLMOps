"""Deterministic pre-deployment evaluation quality gate."""
import json
from pathlib import Path

THRESHOLD = 0.90


def predict(prompt: str) -> str:
    return f"Received: {prompt.strip()}"


def main() -> None:
    cases = json.loads((Path(__file__).parent / "dataset.json").read_text(encoding="utf-8"))
    passed = sum(predict(case["prompt"]) == case["expected"] for case in cases)
    score = passed / len(cases)
    print(f"evaluation_score={score:.2%} threshold={THRESHOLD:.0%}")
    if score < THRESHOLD:
        raise SystemExit("LLM quality gate failed; deployment blocked.")


if __name__ == "__main__":
    main()

