#!/usr/bin/env bash
# Génère un fichier .env avec des secrets aléatoires (jamais versionnés).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env && "${FORCE:-0}" != "1" ]]; then
  echo "[INFO] .env existe déjà — rien à faire (FORCE=1 pour le régénérer)."
  exit 0
fi

command -v openssl >/dev/null 2>&1 || { echo "openssl est requis." >&2; exit 1; }

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
