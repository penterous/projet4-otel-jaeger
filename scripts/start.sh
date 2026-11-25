#!/usr/bin/env bash
# Démarrage guidé : prépare .env, valide la configuration, lance la stack et vérifie.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "[INFO] .env absent — génération des secrets."
  ./scripts/bootstrap.sh
else
  echo "[INFO] .env présent — conservation des secrets existants."
fi

set -a
. ./.env
set +a

echo "[INFO] Validation de la configuration Compose."
docker compose config -q
echo "[OK] Configuration valide."

echo "[INFO] Démarrage des services (build si nécessaire)."
docker compose up -d --build

echo "[INFO] Vérification de la stack."
./scripts/check.sh

printf '\n[OK] Stack prête : http://localhost:%s\n' "${PORT_FRONTEND:-18080}"
printf '[INFO] Pour lancer la démonstration : ./scripts/scenario.sh\n'
