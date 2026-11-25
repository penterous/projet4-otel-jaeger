#!/usr/bin/env bash
# Vérification complète de la stack après docker compose up -d.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "[FAIL] .env absent : lancer ./scripts/bootstrap.sh" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

FAILED=0

printf '\n=== Secrets et variables d environnement ===\n'
for key in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD ADMIN_PASSWORD CHAOS_TOKEN \
           AUTH_USER AUTH_PASSWORD GRAFANA_USER GRAFANA_PASSWORD; do
  value="${!key:-}"
  if [[ -z "$value" || "$value" == EXAMPLE_* ]]; then
    printf '  [FAIL] %-24s absent ou valeur exemple\n' "$key"
    FAILED=$((FAILED + 1))
  else
    printf '  [PASS] %-24s definie\n' "$key"
  fi
done

for key in POSTGRES_PASSWORD ADMIN_PASSWORD CHAOS_TOKEN AUTH_PASSWORD GRAFANA_PASSWORD; do
  value="${!key:-}"
  if (( ${#value} < 16 )); then
    printf '  [FAIL] %-24s trop courte (%d caracteres)\n' "$key" "${#value}"
    FAILED=$((FAILED + 1))
  else
    printf '  [PASS] %-24s longueur suffisante\n' "$key"
  fi
done

for key in PORT_FRONTEND PORT_API PORT_GRAFANA PORT_JAEGER PORT_MAILPIT_UI \
           PORT_MAILPIT_SMTP PORT_PROMETHEUS PORT_ALERTMANAGER PORT_OTLP_GRPC \
           PORT_OTLP_HTTP PORT_COLLECTOR_METRICS; do
  value="${!key:-}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf '  [FAIL] %-24s port invalide\n' "$key"
    FAILED=$((FAILED + 1))
  fi
done

AUTH="${AUTH_USER}:${AUTH_PASSWORD}"

check() {
  local label="$1" url="$2" creds="${3:-}"
  local code
  if [[ -n "$creds" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' -u "$creds" "$url" 2>/dev/null || echo 000)"
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  fi
  if [[ "$code" =~ ^2 ]]; then
    printf '  [PASS] %-30s HTTP %s\n' "$label" "$code"
  else
    printf '  [FAIL] %-30s HTTP %s\n' "$label" "$code"
    FAILED=$((FAILED + 1))
  fi
}

printf '\n=== Etat des conteneurs ===\n'
docker compose ps

printf '\n=== Disponibilite des services ===\n'
check "Frontend (HTML/JS)"       "http://127.0.0.1:${PORT_FRONTEND:-18080}/"
check "API Flask /health"        "http://127.0.0.1:${PORT_API:-18000}/health"
check "API Flask /metrics"       "http://127.0.0.1:${PORT_API:-18000}/metrics"
check "Collector /metrics"       "http://127.0.0.1:${PORT_COLLECTOR_METRICS:-18889}/metrics"
check "Jaeger UI (auth)"         "http://127.0.0.1:${PORT_JAEGER:-18686}/" "$AUTH"
check "Jaeger API (auth)"        "http://127.0.0.1:${PORT_JAEGER:-18686}/api/services" "$AUTH"
check "Prometheus (auth)"        "http://127.0.0.1:${PORT_PROMETHEUS:-19090}/api/v1/status/config" "$AUTH"
check "Alertmanager (auth)"      "http://127.0.0.1:${PORT_ALERTMANAGER:-19093}/api/v2/status" "$AUTH"
check "Grafana (auth)"           "http://127.0.0.1:${PORT_GRAFANA:-13000}/api/health" "${GRAFANA_USER}:${GRAFANA_PASSWORD}"
check "Mailpit (auth)"           "http://127.0.0.1:${PORT_MAILPIT_UI:-18025}/api/v1/messages" "$AUTH"

printf '\n=== Provisioning ===\n'
for uid in g4-direction g4-exploitation; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    "http://127.0.0.1:${PORT_GRAFANA:-13000}/api/dashboards/uid/${uid}" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    printf '  [PASS] Dashboard %s\n' "$uid"
  else
    printf '  [FAIL] Dashboard %s (HTTP %s)\n' "$uid" "$code"
    FAILED=$((FAILED + 1))
  fi
done

RULES="$(curl -fsS -u "$AUTH" "http://127.0.0.1:${PORT_PROMETHEUS:-19090}/api/v1/rules" 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["groups"]; print(sum(len(g["rules"]) for g in d))' 2>/dev/null || echo 0)"
printf '  %s Regles d alerte chargees : %s\n' "$([[ "$RULES" -ge 6 ]] && echo '[PASS]' || echo '[FAIL]')" "$RULES"
[[ "$RULES" -ge 6 ]] || FAILED=$((FAILED + 1))

SPANS="$(curl -fsS "http://127.0.0.1:${PORT_COLLECTOR_METRICS:-18889}/metrics" 2>/dev/null | grep -c 'traces_span_metrics_calls{' || true)"
printf '  %s Metrique spanmetrics presente : %s\n' "$([[ "$SPANS" -gt 0 ]] && echo '[PASS]' || echo '[FAIL]')" "$SPANS"
[[ "$SPANS" -gt 0 ]] || FAILED=$((FAILED + 1))

printf '\n=== Donnees des panneaux Grafana ===\n'
PANELS="$(python3 - <<'PY' 2>/dev/null
import base64, json, os, pathlib, urllib.parse, urllib.request

prom = "http://127.0.0.1:" + os.environ.get("PORT_PROMETHEUS", "19090")
auth = os.environ["AUTH_USER"] + ":" + os.environ["AUTH_PASSWORD"]
token = base64.b64encode(auth.encode()).decode()
total = filled = 0

for name in ("direction", "exploitation"):
    dash = json.loads(pathlib.Path("config/grafana/dashboards/" + name + ".json").read_text())
    for panel in dash.get("panels", []):
        for target in panel.get("targets", []):
            expr = target.get("expr")
            if not expr:
                continue
            total += 1
            url = prom + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
            req = urllib.request.Request(url)
            req.add_header("Authorization", "Basic " + token)
            with urllib.request.urlopen(req, timeout=5) as response:
                data = json.load(response)
            if data.get("status") == "success" and data["data"].get("result"):
                filled += 1

if total and filled == total:
    print("[PASS] Panneaux avec donnees : %d/%d" % (filled, total))
else:
    print("[INFO] Panneaux avec donnees : %d/%d (lancer scenario.sh)" % (filled, total))
PY
)"
printf '  %s\n' "$PANELS"

printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
  echo "[OK] Stack complete et operationnelle."
else
  echo "[FAIL] $FAILED verification(s) en echec."
  exit 1
fi
