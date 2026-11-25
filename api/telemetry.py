"""Initialisation globale d'OpenTelemetry pour le service api-backend."""

import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
from opentelemetry.sdk.resources import (
    DEPLOYMENT_ENVIRONMENT,
    SERVICE_NAME,
    SERVICE_VERSION,
    Resource,
)
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

_configured = False


def configure_telemetry() -> None:
    """Doit être appelé avant l'import de l'application Flask."""
    global _configured
    if _configured:
        return

    resource = Resource.create(
        {
            SERVICE_NAME: "api-backend",
            SERVICE_VERSION: "1.0.0",
            DEPLOYMENT_ENVIRONMENT: os.getenv("OTEL_ENVIRONMENT", "lab"),
            "service.namespace": "g4-observabilite",
        }
    )

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317"),
        insecure=True,
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    FlaskInstrumentor().instrument()
    Psycopg2Instrumentor().instrument()
    LoggingInstrumentor().instrument(set_logging_format=True)

    _configured = True


def get_tracer():
    return trace.get_tracer("api-backend", "1.0.0")
