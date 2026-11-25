"""Point d'entrée WSGI : l'instrumentation doit précéder l'import de l'app."""

from telemetry import configure_telemetry

configure_telemetry()

from app import app  # noqa: E402  (import volontairement après instrumentation)

__all__ = ["app"]
