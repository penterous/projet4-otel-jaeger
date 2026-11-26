#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# Remet l'API en mode nominal et vide la boîte Mailpit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "[FAIL] .env absent" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

curl -fsS -o /dev/null -X POST \
  -H "X-Chaos-Token: ${CHAOS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"mode":"nominal"}' "http://127.0.0.1:${PORT_API:-18000}/internal/chaos" \
  && echo "[OK] Mode chaos : nominal"

if curl -fsS -u "${AUTH_USER}:${AUTH_PASSWORD}" -X DELETE \
    "http://127.0.0.1:${PORT_MAILPIT_UI:-18025}/api/v1/messages" >/dev/null 2>&1; then
  echo "[OK] Boîte Mailpit vidée"
else
  echo "[INFO] Mailpit non vidé (interface indisponible ?)"
fi
