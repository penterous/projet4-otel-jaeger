#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Épreuve du feu — Groupe 4 (OpenTelemetry + Jaeger)
#  1. Trafic nominal       -> traces saines
#  2. Latence SQL 3 s      -> span db.query long + alerte DatabaseSlowQuery
#  3. Exception 500        -> span en erreur + alerte ApiHighErrorRate
#  4. Brute-force admin    -> alerte AdminLoginBruteForce
#  5. Sondage de chemins   -> alerte SuspiciousPathProbing
#  Affiche les Trace ID à copier dans Jaeger, puis l'état des alertes et mail.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "[FAIL] Fichier .env absent : lancer ./scripts/bootstrap.sh" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

API="http://127.0.0.1:${PORT_API:-18000}"
PROM_URL="http://127.0.0.1:${PORT_PROMETHEUS:-19090}"
MAIL_URL="http://127.0.0.1:${PORT_MAILPIT_UI:-18025}"
AUTH_CREDENTIALS="${AUTH_USER}:${AUTH_PASSWORD}"
TMP="$(mktemp -d)"
TRACE_IDS=()
trap 'rm -rf "$TMP"' EXIT

C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'

line() { printf '%s\n' "────────────────────────────────────────────────────────────────────────"; }
phase() { line; printf '%s\n' "${C_BOLD}$1${C_RESET}"; line; }
ok() { printf '  %s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }

wait_for_api() {
  local i
  for i in $(seq 1 90); do
    if curl -fsS "$API/health" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "[FAIL] API indisponible après 90 s : docker compose ps / docker compose logs api" >&2
  exit 1
}

# Appel HTTP générique ; affiche "code trace_id" sur stdout.
call() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}'
              -X "$method" -H 'Content-Type: application/json')
  if [[ -n "$data" ]]; then args+=(-d "$data"); fi
  local code
  code="$(curl "${args[@]}" "${API}${path}" 2>/dev/null || echo 000)"
  local tid
  tid="$(awk 'tolower($1)=="x-trace-id:" {gsub(/\r/,"",$2); print $2}' "$TMP/headers" | tail -1)"
  printf '%s %s' "$code" "${tid:-unknown}"
}

set_mode() {
  curl -fsS -o /dev/null -X POST \
    -H "X-Chaos-Token: ${CHAOS_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"mode\":\"$1\"}" "$API/internal/chaos"
}

record() {
  local code="$1" tid="$2" label="$3"
  TRACE_IDS+=("$tid")
  if [[ "$code" =~ ^2 ]]; then
    printf '  %-22s HTTP %s  %s%s%s\n' "$label" "$code" "$C_CYAN" "$tid" "$C_RESET"
  else
    printf '  %-22s HTTP %s  %s%s%s\n' "$label" "$code" "$C_RED" "$tid" "$C_RESET"
  fi
}

banner() {
  printf '\n%s' "$C_BOLD"
  printf '  ╔══════════════════════════════════════════════════════════════╗\n'
  printf '  ║   GROUPE 4 — ÉPREUVE DU FEU : OBSERVABILITÉ APPLICATIVE     ║\n'
  printf '  ║   OpenTelemetry · Jaeger · Prometheus · Grafana             ║\n'
  printf '  ╚══════════════════════════════════════════════════════════════╝\n'
  printf '%s\n' "$C_RESET"
}

banner
printf 'Attente de l’API... '
wait_for_api
ok "API prête"

# ---------------------------------------------------------------------------
phase "PHASE 1 — Trafic nominal : cascade saine Navigateur → API → PostgreSQL"
set_mode nominal
for i in $(seq 1 8); do
  result="$(call POST /api/checkout "{\"user_id\":$((i % 5 + 1)),\"amount\":$((20 + i * 7)).50}")"
  record "${result%% *}" "${result##* }" "commande #$i"
  sleep 0.2
done
ok "8 traces nominales générées"

# ---------------------------------------------------------------------------
phase "PHASE 2 — Injection d'une latence SQL de 3 secondes"
set_mode slow
for i in 1 2 3; do
  result="$(call POST /api/checkout '{"user_id":2,"amount":75000}')"
  record "${result%% *}" "${result##* }" "commande lente #$i"
done
warn "Regarder le span db.query : db.duration.ms ≈ 3000, db.statement = INSERT INTO orders"

# ---------------------------------------------------------------------------
phase "PHASE 3 — Injection d'une exception non gérée (HTTP 500)"
set_mode error
for i in 1 2 3 4 5; do
  result="$(call POST /api/checkout '{"user_id":3,"amount":75.00}')"
  record "${result%% *}" "${result##* }" "commande en erreur #$i"
done
warn "Dans Jaeger : span checkout en rouge + événement exception avec traceback"

# ---------------------------------------------------------------------------
phase "PHASE 4 — Brute-force du formulaire admin + sondage de chemins sensibles"
for i in $(seq 1 8); do
  result="$(call POST /api/admin/login '{"username":"observadmin","password":"mauvais-mot-de-passe"}')"
  record "${result%% *}" "${result##* }" "login échoué #$i"
done
for p in /.env /admin /wp-login.php /phpmyadmin; do
  result="$(call GET "$p")"
  record "${result%% *}" "${result##* }" "sonde $p"
done
ok "Tentatives d'attaque envoyées"

set_mode nominal
ok "Mode restauré : nominal"

# ---------------------------------------------------------------------------
phase "PHASE 5 — Vérification des alertes et de la notification e-mail"
printf '  Attente de la propagation Alertmanager (40 s)...\n'
sleep 40

printf '\n  %sAlertes actives (Prometheus) :%s\n' "$C_BOLD" "$C_RESET"
curl -fsS -u "$AUTH_CREDENTIALS" "${PROM_URL}/api/v1/alerts" \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)["data"]["alerts"]
if not data:
    print("    (aucune alerte active)")
for a in data:
    print("    {:<30} {:<8} severity={}".format(
        a["labels"].get("alertname", "?"), a["state"], a["labels"].get("severity", "?")))
' 2>/dev/null || warn "Impossible d'interroger Prometheus (curl -u $AUTH_USER ...)"

printf '\n  %sE-mails reçus dans Mailpit :%s\n' "$C_BOLD" "$C_RESET"
MAIL_COUNT="$(curl -fsS -u "$AUTH_CREDENTIALS" "${MAIL_URL}/api/v1/messages" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')"
printf '    %s message(s)\n' "$MAIL_COUNT"

# ---------------------------------------------------------------------------
phase "RÉSULTAT — à copier dans Jaeger (Search by Trace ID)"
for tid in "${TRACE_IDS[@]}"; do printf '  %s\n' "$tid"; done | tail -12

printf '\n  %sInterfaces :%s\n' "$C_BOLD" "$C_RESET"
printf '    Frontend     http://localhost:%s\n' "${PORT_FRONTEND:-18080}"
printf '    Jaeger       http://localhost:%s  (%s/%s)\n' "${PORT_JAEGER:-18686}" "$AUTH_USER" "$AUTH_PASSWORD"
printf '    Grafana      http://localhost:%s   (%s/%s)\n' "${PORT_GRAFANA:-13000}" "${GRAFANA_USER}" "${GRAFANA_PASSWORD}"
printf '    Prometheus   http://localhost:%s   (%s/%s)\n' "${PORT_PROMETHEUS:-19090}" "$AUTH_USER" "$AUTH_PASSWORD"
printf '    Alertmanager http://localhost:%s   (%s/%s)\n' "${PORT_ALERTMANAGER:-19093}" "$AUTH_USER" "$AUTH_PASSWORD"
printf '    Mailpit      http://localhost:%s   (%s/%s)\n' "${PORT_MAILPIT_UI:-18025}" "$AUTH_USER" "$AUTH_PASSWORD"
printf '\n  %sAstuce :%s ./scripts/reset.sh pour repartir d un état propre.\n' "$C_BOLD" "$C_RESET"
printf '\n'
