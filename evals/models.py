from dataclasses import asdict, dataclass
from typing import Any


class DatasetValidationError(ValueError):
    """Evaluation dataset is malformed or unsafe to execute."""


@dataclass(frozen=True, slots=True)
class EvalCase:
    case_id: str
    prompt: str
    expected_output: str
    expected_tool: str | None = None

    @classmethod
    def from_dict(cls, value: Any) -> "EvalCase":
        if not isinstance(value, dict):
            raise DatasetValidationError("Each evaluation case must be an object.")

        required = ("id", "prompt", "expected_output")
        missing = [field for field in required if field not in value]
        if missing:
            raise DatasetValidationError(
                f"Evaluation case is missing fields: {', '.join(missing)}"
            )

        for field in required:
            if not isinstance(value[field], str) or not value[field].strip():
                raise DatasetValidationError(f"Evaluation field '{field}' must be text.")

        expected_tool = value.get("expected_tool")
        if expected_tool is not None and (
            not isinstance(expected_tool, str) or not expected_tool.strip()
        ):
            raise DatasetValidationError(
                "Evaluation field 'expected_tool' must be text or null."
            )

        return cls(
            case_id=value["id"].strip(),
            prompt=value["prompt"],
            expected_output=value["expected_output"],
            expected_tool=expected_tool.strip() if expected_tool else None,
        )


@dataclass(frozen=True, slots=True)
class Prediction:
    output: str
    tool_name: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    estimated_cost_usd: float | None = None


@dataclass(frozen=True, slots=True)
class EvalResult:
    case_id: str
    expected_output: str
    actual_output: str
    latency_ms: float
    expected_tool: str | None
    actual_tool: str | None
    tool_success: bool | None
    input_tokens: int | None
    output_tokens: int | None
    estimated_cost_usd: float | None
    error_type: str | None = None


@dataclass(frozen=True, slots=True)
class EvalScores:
    accuracy: float
    tool_success_rate: float | None
    p95_latency_ms: float
    estimated_cost_usd: float | None


@dataclass(frozen=True, slots=True)
class EvalReport:
    case_count: int
    accuracy: float
    tool_success_rate: float | None
    p95_latency_ms: float
    estimated_cost_usd: float | None
    overall_status: str
    failures: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["failures"] = list(self.failures)
        return payload

