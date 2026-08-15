from opentelemetry import trace
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags

from services.common.observability.tracing import (
    current_trace_ids,
    extract_trace_context,
    inject_trace_context,
)


def test_xray_context_round_trip_preserves_trace_without_business_data():
    span_context = SpanContext(
        trace_id=0x1234567890ABCDEF1234567890ABCDEF,
        span_id=0x1234567890ABCDEF,
        is_remote=False,
        trace_flags=TraceFlags.SAMPLED,
    )

    with trace.use_span(NonRecordingSpan(span_context)):
        carrier = inject_trace_context()
        assert current_trace_ids() == (
            "1234567890abcdef1234567890abcdef",
            "1234567890abcdef",
        )

    assert carrier is not None
    assert set(carrier) == {"X-Amzn-Trace-Id"}
    extracted = trace.get_current_span(
        extract_trace_context(carrier)
    ).get_span_context()
    assert extracted.trace_id == span_context.trace_id
    assert extracted.span_id == span_context.span_id
    assert extracted.is_remote


def test_no_active_span_produces_no_queue_trace_context():
    assert inject_trace_context() is None
    assert current_trace_ids() is None
