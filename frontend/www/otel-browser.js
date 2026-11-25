/* --------------------------------------------------------------------------
 * otel-browser.js — miniature OTLP/HTTP JSON tracer (aucun bundler requis).
 * Crée un span racine côté navigateur, injecte W3C traceparent dans fetch(),
 * puis exporte le span vers le Collector. L'API Flask hérite du Trace ID :
 * Jaeger affiche donc une cascade Navigateur -> API -> PostgreSQL.
 * ------------------------------------------------------------------------ */
(function () {
  "use strict";

  var OTLP_URL = "/v1/traces";
  var SERVICE_NAME = "frontend-web";

  function toHex(bytes) {
    return Array.prototype.map.call(bytes, function (b) {
      return b.toString(16).padStart(2, "0");
    }).join("");
  }

  function randomHex(length) {
    var bytes = new Uint8Array(length);
    crypto.getRandomValues(bytes);
    return toHex(bytes);
  }

  function nowNano() {
    return (BigInt(Date.now()) * 1000000n).toString();
  }

  function attr(key, value) {
    if (typeof value === "number") {
      return { key: key, value: { intValue: String(Math.trunc(value)) } };
    }
    if (typeof value === "boolean") {
      return { key: key, value: { boolValue: value } };
    }
    return { key: key, value: { stringValue: String(value) } };
  }

  function startSpan(name, attributes) {
    return {
      traceId: randomHex(16),
      spanId: randomHex(8),
      name: name,
      kind: 3,
      startTimeUnixNano: nowNano(),
      attributes: attributes || []
    };
  }

  function traceparent(span) {
    return "00-" + span.traceId + "-" + span.spanId + "-01";
  }

  function exportSpan(span, statusCode, attributes, events) {
    var attrs = (span.attributes || []).concat(attributes || []);
    var payload = {
      resourceSpans: [{
        resource: {
          attributes: [
            attr("service.name", SERVICE_NAME),
            attr("service.version", "1.0.0"),
            attr("service.namespace", "g4-observabilite"),
            attr("telemetry.sdk.name", "browser-lite"),
            attr("telemetry.sdk.language", "webjs")
          ]
        },
        scopeSpans: [{
          scope: { name: "g4-browser-tracer", version: "1.0.0" },
          spans: [{
            traceId: span.traceId,
            spanId: span.spanId,
            name: span.name,
            kind: span.kind,
            startTimeUnixNano: span.startTimeUnixNano,
            endTimeUnixNano: nowNano(),
            status: { code: statusCode || 1 },
            attributes: attrs,
            events: events || []
          }]
        }]
      }]
    };

    try {
      fetch(OTLP_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        mode: "cors",
        keepalive: true
      }).catch(function () { /* l'UI ne doit jamais dépendre du collecteur */ });
    } catch (e) { /* silencieux */ }
  }

  window.OtelBrowser = {
    startSpan: startSpan,
    traceparent: traceparent,
    exportSpan: exportSpan,
    attr: attr,
    randomHex: randomHex
  };
})();
