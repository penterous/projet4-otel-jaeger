/* Contrôleur de l'interface : chaque appel crée un span navigateur et
 * propage le contexte W3C traceparent vers l'API Flask. */

(function () {
  "use strict";

  var state = { requests: 0, errors: 0, orders: 0, lastTrace: null };
  var $ = function (id) { return document.getElementById(id); };
  var money = function (value) {
    return new Intl.NumberFormat("fr-FR").format(Math.round(Number(value) || 0)) + " FCFA";
  };
  var CFG = window.G4_CONFIG || {
    jaeger: "http://localhost:18686",
    grafana: "http://localhost:13000",
    prometheus: "http://localhost:19090",
    mailpit: "http://localhost:18025"
  };
  $("link-jaeger").href = CFG.jaeger;
  $("link-grafana").href = CFG.grafana;
  $("link-prometheus").href = CFG.prometheus;
  $("link-mailpit").href = CFG.mailpit;

  function stamp() {
    return new Date().toLocaleTimeString("fr-FR", { hour12: false });
  }

  function log(message, level, traceId) {
    var list = $("log-list");
    if (list.querySelector(".log-empty")) { list.innerHTML = ""; }
    var li = document.createElement("li");
    var time = document.createElement("time");
    time.textContent = stamp();
    var text = document.createElement("span");
    text.className = level || "ok";
    text.textContent = message;
    li.appendChild(time);
    li.appendChild(text);
    if (traceId) {
      var tid = document.createElement("span");
      tid.className = "tid";
      tid.textContent = traceId.slice(0, 12) + "…";
      li.appendChild(tid);
    }
    list.insertBefore(li, list.firstChild);
    while (list.children.length > 40) { list.removeChild(list.lastChild); }
  }

  function updateTrace(traceId, spanId, mode) {
    state.lastTrace = traceId;
    $("trace-id").textContent = traceId;
    $("span-id").textContent = spanId ? spanId.slice(0, 8) + "…" : "—";
    if (mode) { $("chaos-mode").textContent = mode; }
    $("open-jaeger").href = CFG.jaeger + "/trace/" + traceId;
  }

  async function tracedFetch(path, label, options) {
    var span = window.OtelBrowser.startSpan("frontend." + label, [
      window.OtelBrowser.attr("http.method", (options && options.method) || "GET"),
      window.OtelBrowser.attr("http.url", path),
      window.OtelBrowser.attr("app.feature", label)
    ]);
    var headers = Object.assign({}, (options && options.headers) || {});
    headers["traceparent"] = window.OtelBrowser.traceparent(span);
    var started = performance.now();

    var response = await fetch(path, Object.assign({}, options, { headers: headers }));
    var elapsed = performance.now() - started;
    var body = await response.json().catch(function () { return {}; });

    state.requests += 1;
    $("stat-requests").textContent = state.requests;
    $("stat-latency").innerHTML = Math.round(elapsed) + "<small> ms</small>";
    if (response.status >= 400) {
      state.errors += 1;
      $("stat-errors").textContent = state.errors;
    }

    window.OtelBrowser.exportSpan(
      span,
      response.ok ? 1 : 2,
      [
        window.OtelBrowser.attr("http.response.status_code", response.status),
        window.OtelBrowser.attr("http.duration.ms", Math.round(elapsed)),
        window.OtelBrowser.attr("app.trace_id", body.trace_id || span.traceId)
      ],
      response.ok ? [] : [{
        name: "exception",
        attributes: [window.OtelBrowser.attr("exception.message", "HTTP " + response.status)],
        timeUnixNano: (BigInt(Date.now()) * 1000000n).toString()
      }]
    );

    var traceId = body.trace_id || response.headers.get("X-Trace-Id") || span.traceId;
    updateTrace(traceId, body.span_id || response.headers.get("X-Span-Id"),
                response.headers.get("X-Chaos-Mode"));
    return { ok: response.ok, status: response.status, body: body, traceId: traceId };
  }

  function showResult(text) { $("last-result").textContent = text; }

  async function checkout(amount) {
    var button = $("btn-order");
    button.disabled = true;
    try {
      var r = await tracedFetch("/api/checkout", "checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: 1 + Math.floor(Math.random() * 5), amount: amount || 15000 })
      });
      if (r.ok) { state.orders += 1; }
      showResult(r.ok
        ? "Commande #" + r.body.order_id + " créée · " + money(r.body.total_fcfa)
        : "Erreur " + r.status + " — voir le Trace ID dans Jaeger");
      log(r.ok ? "Commande créée" : "Échec checkout (HTTP " + r.status + ")",
          r.ok ? "ok" : "err", r.traceId);
    } catch (e) {
      log("API injoignable — vérifier docker compose ps", "err");
      showResult("API injoignable");
    } finally {
      button.disabled = false;
    }
  }

  async function refreshOrders() {
    var r = await tracedFetch("/api/orders", "list_orders");
    if (r.ok) { $("stat-orders").textContent = r.body.count; }
    showResult(r.body.count + " commandes lues depuis PostgreSQL");
    log(r.body.count + " commandes lues", "ok", r.traceId);
  }

  async function refreshUsers() {
    var r = await tracedFetch("/api/users", "list_users");
    showResult(r.ok ? r.body.count + " utilisateurs lus" : "Erreur " + r.status);
    log(r.body.count + " utilisateurs lus", "ok", r.traceId);
  }

  async function health() {
    var r = await tracedFetch("/health", "health");
    log(r.ok ? "Service " + r.body.service + " · " + r.body.status : "Santé dégradée",
        r.ok ? "ok" : "warn", r.traceId);
  }

  async function burst() {
    var button = $("btn-burst");
    button.disabled = true;
    log("Début du trafic soutenu (10 commandes)", "warn");
    for (var i = 0; i < 10; i++) {
      await checkout((50 + Math.floor(Math.random() * 451)) * 100);
      await new Promise(function (resolve) { setTimeout(resolve, 120); });
    }
    log("Trafic soutenu terminé", "ok");
    button.disabled = false;
  }

  $("btn-order").addEventListener("click", function () { checkout(); });
  $("btn-users").addEventListener("click", refreshUsers);
  $("btn-orders").addEventListener("click", refreshOrders);
  $("btn-health").addEventListener("click", health);
  $("btn-burst").addEventListener("click", burst);

  refreshOrders().then(health).catch(function () {
    log("Initialisation impossible — API non démarrée ?", "err");
  });
})();
