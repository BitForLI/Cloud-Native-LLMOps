"""OpenTelemetry tracing configured for an ECS-local ADOT Collector."""

from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from threading import Lock

from opentelemetry import context, propagate, trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
from opentelemetry.propagators.aws import AwsXRayPropagator
from opentelemetry.sdk.extension.aws.trace import AwsXRayIdGenerator
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
from opentelemetry.trace import SpanKind, Status, StatusCode

_configuration_lock = Lock()
_tracer_provider: TracerProvider | None = None
_xray_propagator = AwsXRayPropagator()


def configure_tracing(
    service_name: str,
    environment: str,
    endpoint: str | None,
    sample_ratio: float,
) -> TracerProvider | None:
    """Configure one fail-soft OTLP pipeline per process, or disable locally."""

    global _tracer_provider
    if endpoint is None:
        return None
    if endpoint != "http://127.0.0.1:4317":
        raise ValueError("OTLP endpoint must be the ECS-local ADOT Collector")
    if not 0 <= sample_ratio <= 1:
        raise ValueError("trace sample ratio must be between 0 and 1")

    with _configuration_lock:
        if _tracer_provider is not None:
            return _tracer_provider

        provider = TracerProvider(
            resource=Resource.create(
                {
                    "service.name": service_name,
                    "service.namespace": "cloud-native-llmops",
                    "deployment.environment.name": environment,
                }
            ),
            sampler=ParentBased(TraceIdRatioBased(sample_ratio)),
            id_generator=AwsXRayIdGenerator(),
        )
        exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True, timeout=5)
        provider.add_span_processor(BatchSpanProcessor(exporter))
        trace.set_tracer_provider(provider)
        propagate.set_global_textmap(_xray_propagator)
        BotocoreInstrumentor().instrument(tracer_provider=provider)
        _tracer_provider = provider
        return provider


def inject_trace_context() -> dict[str, str] | None:
    """Serialize only the X-Ray propagation header for an asynchronous task."""

    carrier: dict[str, str] = {}
    _xray_propagator.inject(carrier)
    return carrier or None


def extract_trace_context(carrier: Mapping[str, str] | None) -> context.Context | None:
    if not carrier:
        return None
    return _xray_propagator.extract(dict(carrier))


@contextmanager
def job_span(
    job_id: str,
    model_id: str,
    carrier: Mapping[str, str] | None,
) -> Iterator[trace.Span]:
    """Continue the submitting request trace without attaching prompt content."""

    tracer = trace.get_tracer("llmops.jobs")
    with tracer.start_as_current_span(
        "inference.job.process",
        context=extract_trace_context(carrier),
        kind=SpanKind.CONSUMER,
        attributes={
            "job.id": job_id,
            "llm.model": model_id,
            "messaging.system": "aws_sqs",
        },
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        yield span


@contextmanager
def inference_span(model_id: str) -> Iterator[trace.Span]:
    """Create a prompt-free model invocation span."""

    tracer = trace.get_tracer("llmops.inference")
    provider = "local" if model_id.startswith("local-") else "amazon_bedrock"
    with tracer.start_as_current_span(
        "llm.generate",
        kind=SpanKind.CLIENT,
        attributes={"llm.provider": provider, "llm.model": model_id},
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        yield span


def mark_current_span_error(error: Exception) -> None:
    """Record only the safe exception type, never its potentially sensitive text."""

    span = trace.get_current_span()
    span.set_attribute("error.type", type(error).__name__)
    span.set_status(Status(StatusCode.ERROR))


def current_trace_ids() -> tuple[str, str] | None:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return None
    return f"{span_context.trace_id:032x}", f"{span_context.span_id:016x}"
