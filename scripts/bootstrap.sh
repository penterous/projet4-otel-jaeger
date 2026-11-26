#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# Génère un fichier .env avec des secrets aléatoires (jamais versionnés).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env && "${FORCE:-0}" != "1" ]]; then
  echo "[INFO] .env existe déjà — rien à faire (FORCE=1 pour le régénérer)."
  exit 0
fi

command -v openssl >/dev/null 2>&1 || { echo "openssl est requis." >&2; exit 1; }

if [[ ! -f .env.example ]]; then
  cat > .env.example <<'EOF'
POSTGRES_DB=shopdb
POSTGRES_USER=shop_app
POSTGRES_PASSWORD=EXAMPLE_CHANGE_ME_POSTGRES
ADMIN_PASSWORD=EXAMPLE_CHANGE_ME_ADMIN
CHAOS_TOKEN=EXAMPLE_CHANGE_ME_CHAOS
OTEL_ENVIRONMENT=lab
AUTH_USER=admin
AUTH_PASSWORD=EXAMPLE_CHANGE_ME_AUTH
GRAFANA_USER=observadmin
GRAFANA_PASSWORD=EXAMPLE_CHANGE_ME_GRAFANA
ALERT_EMAIL=soc@monitoring.lab
PORT_FRONTEND=18080
PORT_API=18000
PORT_GRAFANA=13000
PORT_JAEGER=18686
PORT_MAILPIT_UI=18025
PORT_MAILPIT_SMTP=11025
PORT_PROMETHEUS=19090
PORT_ALERTMANAGER=19093
PORT_OTLP_GRPC=14317
PORT_OTLP_HTTP=14318
PORT_COLLECTOR_METRICS=18889
EOF
fi

cp .env.example .env
secret() { openssl rand -hex 16; }

replace() {
  local key="$1" value="$2"
  sed -i.bak "s|^${key}=.*|${key}=${value}|" .env
  rm -f .env.bak
}

replace POSTGRES_PASSWORD "$(secret)"
replace ADMIN_PASSWORD "$(secret)"
replace CHAOS_TOKEN "$(secret)"
replace AUTH_PASSWORD "$(secret)"
replace GRAFANA_PASSWORD "$(secret)"

chmod 600 .env
echo "[OK] .env généré avec 5 secrets aléatoires (droits 600)."
echo
echo "Prochaines commandes :"
echo "  docker compose up -d --build"
echo "  ./scripts/scenario.sh"
