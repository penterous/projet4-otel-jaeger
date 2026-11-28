/* Contrôleur de l'interface : chaque appel crée un span navigateur et
 * propage le contexte W3C traceparent vers l'API Flask.
 * L'interface ne s'anime que lorsque l'information change réellement. */

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

  ["jaeger", "grafana", "prometheus", "mailpit"].forEach(function (key) {
    $("link-" + key).href = CFG[key];
    $("tile-" + key).href = CFG[key];
  });

  function stamp() {
    return new Date().toLocaleTimeString("fr-FR", { hour12: false });
  }

  function motionOff() {
    return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  /* ---- Valeurs ---------------------------------------------------------- */
  var displayed = {};
  var tokens = {};

  function setNumber(id, value, duration) {
    var el = $(id);
    var to = Number(value) || 0;
    var from = Number(displayed[id]);
    if (!isFinite(from)) { from = 0; }
    var token = (tokens[id] || 0) + 1;
    tokens[id] = token;

    if (motionOff() || from === to) {
      displayed[id] = to;
      el.textContent = String(to);
      return;
    }
    var start = performance.now();
    var span = duration || 420;
    function frame(now) {
      if (tokens[id] !== token) { return; }
      var p = Math.min(1, (now - start) / span);
      var eased = 1 - Math.pow(1 - p, 3);
      el.textContent = String(Math.round(from + (to - from) * eased));
      if (p < 1) { requestAnimationFrame(frame); }
      else { displayed[id] = to; }
    }
    requestAnimationFrame(frame);
  }

  function showResult(text) { $("last-result-text").textContent = text; }

  /* ---- Trace ------------------------------------------------------------ */
  function renderWaterfall(traceId) {
    var names = ["browser.root", "api.checkout", "db.query", "otlp.export", "jaeger.ingest"];
    var seed = 0;
    for (var c = 0; c < traceId.length; c++) { seed = (seed * 31 + traceId.charCodeAt(c)) >>> 0; }
    function rand(i) {
      var x = Math.sin(seed * 0.001 + i * 17.13) * 10000;
      return x - Math.floor(x);
    }
    var widths = names.map(function (_, i) { return 22 + Math.round(rand(i) * 70); });
    var slowest = widths.indexOf(Math.max.apply(null, widths));
    var rows = names.map(function (name, i) {
      var ms = Math.round(widths[i] * 1.4 + rand(i + 11) * 18);
      return '<div class="wf"><span class="wf-name">' + name + '</span>' +
             '<span class="wf-track"><i class="wf-bar' + (i === slowest ? ' is-slow' : '') +
             '" style="--w:' + widths[i] + '%"></i></span>' +
             '<span class="wf-ms">' + ms + 'ms</span></div>';
    }).join("");
    $("trace-bars").innerHTML = rows +
      '<div class="wf-axis"><span>0</span><span>25</span><span>50</span><span>75</span><span>100 ms</span></div>';
  }

  function updateTrace(traceId, spanId, mode) {
    state.lastTrace = traceId;
    $("trace-id").textContent = traceId;
    $("span-id").textContent = spanId ? spanId.slice(0, 8) + "…" : "—";
    if (mode) { $("chaos-mode").textContent = mode; }
    $("open-jaeger").href = CFG.jaeger + "/trace/" + traceId;
    renderWaterfall(traceId);
  }

  /* ---- Journal ---------------------------------------------------------- */
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

  function setBurst(active, progress) {
    $("burst-meter").classList.toggle("is-active", !!active);
    $("burst-bar").style.width = Math.round((progress || 0) * 100) + "%";
    $("burst-label").textContent = active
      ? "Générateur de trafic · " + Math.round(progress * 100) + "%"
      : "Générateur de trafic · en veille";
  }

  /* ---- Requêtes instrumentées ------------------------------------------ */
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
    setNumber("stat-requests", state.requests, 260);
    setNumber("stat-latency", Math.round(elapsed), 480);
    if (response.status >= 400) {
      state.errors += 1;
      setNumber("stat-errors", state.errors, 300);
      $("stat-errors").closest(".stat").classList.add("is-alert");
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
    if (r.ok) {
      state.orders = r.body.count;
      setNumber("stat-orders", state.orders, 700);
    }
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
    var ok = r.ok && r.body.status === "ok";
    $("health-dot").className = "live-dot " + (ok ? "is-ok" : "is-err");
    $("health-state").textContent = ok ? r.body.service + " · ok" : "santé dégradée";
    log(r.ok ? "Service " + r.body.service + " · " + r.body.status : "Santé dégradée",
        ok ? "ok" : "warn", r.traceId);
  }

  async function burst() {
    var button = $("btn-burst");
    button.disabled = true;
    log("Début du trafic soutenu (10 commandes)", "warn");
    for (var i = 0; i < 10; i++) {
      await checkout((50 + Math.floor(Math.random() * 451)) * 100);
      setBurst(true, (i + 1) / 10);
      await new Promise(function (resolve) { setTimeout(resolve, 120); });
    }
    log("Trafic soutenu terminé", "ok");
    setTimeout(function () { setBurst(false, 0); }, 700);
    button.disabled = false;
  }

  /* ---- Initialisation --------------------------------------------------- */
  $("btn-order").addEventListener("click", function () { checkout(); });
  $("btn-users").addEventListener("click", refreshUsers);
  $("btn-orders").addEventListener("click", refreshOrders);
  $("btn-health").addEventListener("click", health);
  $("btn-burst").addEventListener("click", burst);

  $("clock").textContent = stamp();
  setInterval(function () { $("clock").textContent = stamp(); }, 1000);

  refreshOrders().then(health).catch(function () {
    log("Initialisation impossible — API non démarrée ?", "err");
    $("health-dot").className = "live-dot is-err";
    $("health-state").textContent = "API hors ligne";
  });
})();
