#!/bin/sh
# Génère le fichier basic-auth à partir des secrets .env, sans rien versionner.
set -eu

: "${AUTH_USER:?La variable AUTH_USER est obligatoire}"
: "${AUTH_PASSWORD:?La variable AUTH_PASSWORD est obligatoire}"

htpasswd -b -c /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
echo "[gateway] basic-auth configuré pour l'utilisateur ${AUTH_USER}"
