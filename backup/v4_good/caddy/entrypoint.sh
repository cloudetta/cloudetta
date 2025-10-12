#!/bin/sh
set -e

MODE="${1:-local}"
CFG_DIR="/etc/caddy"

echo "[caddy] MODE=${MODE}"

if [ "$MODE" = "local" ]; then
  cp -f "$CFG_DIR/Caddyfile.local" "$CFG_DIR/Caddyfile"
else
  if ! command -v envsubst >/dev/null 2>&1; then
    echo "[caddy] ERROR: envsubst non presente. Installa gettext-base (già previsto nel compose)"; exit 1
  fi
  export DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN MATTERMOST_DOMAIN \
         KEYCLOAK_DOMAIN GRAFANA_DOMAIN LOKI_DOMAIN UPTIMEKUMA_DOMAIN ERRORS_DOMAIN MINIO_DOMAIN COLLABORA_DOMAIN CROWDSEC_DOMAIN CADDY_EMAIL
  envsubst < "$CFG_DIR/Caddyfile.prod.tmpl" > "$CFG_DIR/Caddyfile"
fi

echo "[caddy] Validazione Caddyfile…"
caddy validate --config "$CFG_DIR/Caddyfile" --adapter caddyfile
echo "[caddy] Avvio…"
exec caddy run --config "$CFG_DIR/Caddyfile" --adapter caddyfile
