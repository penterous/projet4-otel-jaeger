"""API backend du Groupe 4 — e-commerce minimaliste, instrumentée OTel.

Les 3 piliers de l'observabilité sont démontrés ici :
  * Traces  : spans Flask + spans db.query + attributs métier, export OTLP/gRPC
  * Métriques : compteurs/histogrammes Prometheus (méthode RED)
  * Logs    : LoggingInstrumentor injecte trace_id / span_id dans les logs
"""

import os
import time
from typing import Any

import psycopg2
from flask import Flask, Response, jsonify, request
from opentelemetry import trace
from opentelemetry.trace import SpanKind, Status, StatusCode
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from psycopg2.extras import RealDictCursor
from werkzeug.exceptions import HTTPException

from telemetry import get_tracer

DSN = os.environ["DATABASE_URL"]
ADMIN_PASSWORD = os.environ["ADMIN_PASSWORD"]
CHAOS_TOKEN = os.environ["CHAOS_TOKEN"]

VALID_MODES = {"nominal", "slow", "error"}
CHAOS = {"mode": "nominal"}

app = Flask(__name__)
app.config["PROPAGATE_EXCEPTIONS"] = False
app.json.sort_keys = False

# --------------------------------------------------------------------------
# Métriques applicatives (RED + sécurité)
# --------------------------------------------------------------------------
REQUESTS = Counter(
    "http_requests_total", "Nombre de requêtes HTTP", ["method", "route", "status"]
)
REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "Durée des requêtes HTTP",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
)
DB_LATENCY = Histogram(
    "app_db_query_duration_seconds",
    "Durée des requêtes PostgreSQL",
    ["operation"],
    buckets=(0.005, 0.01, 0.05, 0.1, 0.5, 1, 2, 3, 5, 10),
)
SLOW_QUERIES = Counter(
    "app_slow_queries_total", "Requêtes SQL dépassant 1 s", ["route"]
)
AUTH_FAILURES = Counter(
    "app_auth_failures_total", "Échecs d'authentification", ["route", "reason"]
)
UNHANDLED_ERRORS = Counter(
    "app_unhandled_errors_total", "Exceptions non gérées", ["route"]
)
SUSPICIOUS_REQUESTS = Counter(
    "app_suspicious_requests_total", "Requêtes vers des chemins sensibles", ["path"]
)
ORDERS = Counter("app_orders_total", "Commandes", ["status"])
ACTIVE_USERS = Gauge("app_active_users", "Utilisateurs actifs (simulation)")

SUSPICIOUS_PATHS = ("/.env", "/wp-login.php", "/phpmyadmin", "/admin", "../")


def current_trace_id() -> str:
    return format(trace.get_current_span().get_span_context().trace_id, "032x")


def current_span_id() -> str:
    return format(trace.get_current_span().get_span_context().span_id, "016x")


# --------------------------------------------------------------------------
# Accès base de données avec span SQL explicite
# --------------------------------------------------------------------------
def execute(sql: str, params: tuple | None = None, *, slow: bool = False,
            operation: str = "select") -> list[dict[str, Any]]:
    """Exécute une requête et matérialise un span db.query avec attributs métier."""
    span = trace.get_current_span()
    span.set_attribute("db.system", "postgresql")
    span.set_attribute("db.name", "shopdb")
    span.set_attribute("db.operation", operation)
    span.set_attribute("db.statement", " ".join(sql.split()))

    conn = None
    started = time.perf_counter()
    try:
        conn = psycopg2.connect(DSN, connect_timeout=5)
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            if slow:
                # Latence SQL realiste : 3 secondes mesurées dans le span.
                cur.execute("SELECT pg_sleep(3)")
                cur.fetchall()
            cur.execute(sql, params or ())
            rows = cur.fetchall() if cur.description else []
        conn.commit()

        duration_ms = (time.perf_counter() - started) * 1000
        span.set_attribute("db.duration.ms", round(duration_ms, 2))
        DB_LATENCY.labels(operation=operation).observe(duration_ms / 1000)
        if duration_ms > 1000:
            SLOW_QUERIES.labels(route=request.path).inc()
            span.set_attribute("app.slow_query", True)
        return [dict(row) for row in rows]
    except Exception as exc:
        span.record_exception(exc)
        span.set_status(Status(StatusCode.ERROR, str(exc)))
        raise
    finally:
        if conn is not None:
            conn.close()


# --------------------------------------------------------------------------
# Middleware : métrologie RED + détection de chemins sensibles
# --------------------------------------------------------------------------
@app.before_request
def before_request():
    span = trace.get_current_span()
    span.set_attribute("app.service", "api-backend")
    span.set_attribute("app.chaos_mode", CHAOS["mode"])

    for marker in SUSPICIOUS_PATHS:
        if marker in request.path:
            SUSPICIOUS_REQUESTS.labels(path=request.path).inc()
            span.set_attribute("app.security.suspicious", True)
            span.add_event("security.suspicious_path", {"app.path": request.path})
            break


@app.after_request
def after_request(response: Response) -> Response:
    route = request.endpoint or "unknown"
    REQUESTS.labels(method=request.method, route=route, status=response.status_code).inc()
    REQUEST_DURATION.labels(method=request.method, route=route).observe(
        max(0.0, time.perf_counter() - getattr(request, "started_at", time.perf_counter()))
    )
    # Le navigateur et scenario.sh récupèrent le Trace ID pour le diagnostic.
    response.headers["X-Trace-Id"] = current_trace_id()
    response.headers["X-Span-Id"] = current_span_id()
    response.headers["X-Chaos-Mode"] = CHAOS["mode"]
    return response


@app.before_request
def start_timer():
    request.started_at = time.perf_counter()


@app.errorhandler(Exception)
def handle_exception(exc):
    if isinstance(exc, HTTPException):
        return exc
    UNHANDLED_ERRORS.labels(route=request.endpoint or "unknown").inc()
    span = trace.get_current_span()
    span.record_exception(exc)
    span.set_status(Status(StatusCode.ERROR, str(exc)))
    app.logger.error("Exception non gérée: %s", exc)
    return jsonify({
        "error": "internal_server_error",
        "message": str(exc),
        "trace_id": current_trace_id(),
        "hint": "Copier ce Trace ID dans Jaeger > Search by Trace ID",
    }), 500


# --------------------------------------------------------------------------
# Routes opérationnelles
# --------------------------------------------------------------------------
@app.get("/health")
def health():
    execute("SELECT 1 AS ok", operation="healthcheck")
    return jsonify({
        "status": "ok",
        "service": "api-backend",
        "chaos_mode": CHAOS["mode"],
        "trace_id": current_trace_id(),
    })


@app.get("/api/version")
def version():
    return jsonify({"service": "api-backend", "version": "1.0.0",
                    "stack": "Flask + PostgreSQL + OpenTelemetry",
                    "trace_id": current_trace_id()})


@app.get("/api/users")
def users():
    rows = execute("SELECT id, email, full_name, created_at FROM users ORDER BY id")
    trace.get_current_span().set_attribute("app.user.count", len(rows))
    return jsonify({"count": len(rows), "users": rows,
                    "trace_id": current_trace_id()})


@app.get("/api/orders")
def orders():
    rows = execute(
        "SELECT o.id, u.email, o.total_fcfa, o.status, o.created_at "
        "FROM orders o JOIN users u ON u.id = o.user_id ORDER BY o.id DESC LIMIT 20"
    )
    trace.get_current_span().set_attribute("app.order.count", len(rows))
    return jsonify({"count": len(rows), "orders": rows,
                    "trace_id": current_trace_id()})


@app.post("/api/checkout")
def checkout():
    payload = request.get_json(silent=True) or {}
    try:
        user_id = int(payload.get("user_id", 1))
        amount = float(payload.get("amount", 15000))
    except (TypeError, ValueError):
        return jsonify({"error": "invalid_payload"}), 400

    span = trace.get_current_span()
    span.set_attribute("app.feature", "checkout")
    span.set_attribute("app.user.id", user_id)
    span.set_attribute("app.order.amount_fcfa", amount)

    with get_tracer().start_as_current_span("app.validate_cart") as validate_span:
        validate_span.set_attribute("app.cart.items", 2)
        validate_span.set_attribute("app.cart.currency", "XOF")
        time.sleep(0.01)

    rows = execute(
        "INSERT INTO orders (user_id, total_fcfa, status) "
        "VALUES (%s, %s, 'paid') RETURNING id, total_fcfa, status",
        (user_id, amount),
        slow=(CHAOS["mode"] == "slow"),
        operation="insert",
    )
    order = dict(rows[0])
    span.set_attribute("app.order.id", order["id"])

    if CHAOS["mode"] == "error":
        raise RuntimeError(
            "Chaos injecté : exception non gérée dans checkout (erreur 500 simulée)"
        )

    ORDERS.labels(status="success").inc()
    ACTIVE_USERS.set(min(50, 3 + int(time.time()) % 7))
    return jsonify({
        "order_id": order["id"],
        "total_fcfa": order["total_fcfa"],
        "status": "paid",
        "trace_id": current_trace_id(),
        "span_id": current_span_id(),
    }), 201


@app.post("/api/admin/login")
def admin_login():
    payload = request.get_json(silent=True) or {}
    username = str(payload.get("username", ""))
    password = str(payload.get("password", ""))
    span = trace.get_current_span()
    span.set_attribute("app.user.login", username)
    span.set_attribute("app.security.event", "login_attempt")

    if username != "observadmin" or password != ADMIN_PASSWORD:
        AUTH_FAILURES.labels(route="/api/admin/login", reason="bad_credentials").inc()
        span.set_attribute("app.auth.success", False)
        span.add_event("auth.failure", {"app.user.login": username})
        return jsonify({"error": "unauthorized", "trace_id": current_trace_id()}), 401

    span.set_attribute("app.auth.success", True)
    return jsonify({"token": "demo-token", "trace_id": current_trace_id()})


@app.post("/internal/chaos")
def set_chaos():
    """Endpoint interne protégé par token : injection contrôlée des pannes."""
    if request.headers.get("X-Chaos-Token") != CHAOS_TOKEN:
        return jsonify({"error": "forbidden"}), 403
    payload = request.get_json(silent=True) or {}
    mode = str(payload.get("mode", "")).lower()
    if mode not in VALID_MODES:
        return jsonify({"error": "invalid_mode", "valid_modes": sorted(VALID_MODES)}), 400
    previous = CHAOS["mode"]
    CHAOS["mode"] = mode
    trace.get_current_span().set_attribute("app.chaos.previous_mode", previous)
    trace.get_current_span().add_event("chaos.mode_changed", {"app.chaos.mode": mode})
    app.logger.warning("Mode chaos: %s -> %s", previous, mode)
    return jsonify({"previous": previous, "mode": mode})


@app.get("/internal/chaos")
def get_chaos():
    if request.headers.get("X-Chaos-Token") != CHAOS_TOKEN:
        return jsonify({"error": "forbidden"}), 403
    return jsonify({"mode": CHAOS["mode"]})


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)
