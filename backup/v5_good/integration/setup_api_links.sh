#!/usr/bin/env bash
set -euo pipefail

echo "=== Configurazione integrazione API tra sistemi ==="

# --- Caricamento variabili d'ambiente -----------------------------------------
# Usa .env se esiste, altrimenti .env.example. Non fallire se mancano.
if [ -f ".env" ]; then
  set -a
  . ./.env
  set +a
elif [ -f ".env.example" ]; then
  set -a
  . ./.env.example
  set +a
fi

# --- Endpoints interni dei servizi (come da docker-compose) -------------------
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
ODOO_URL="${ODOO_URL:-http://odoo:8069}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
N8N_URL="${N8N_URL:-http://n8n:5678}"

# --- Credenziali/parametri con default sensati --------------------------------
DJANGO_USER="${DJANGO_USER:-admin}"
DJANGO_PASS="${DJANGO_PASS:-admin}"

ODOO_USER="${ODOO_USER:-admin}"
ODOO_PASS="${ODOO_PASS:-admin}"

# Per Redmine serve una API key valida (puoi esportarla in .env come REDMINE_API_KEY)
REDMINE_API_KEY="${REDMINE_API_KEY:-}"
if [ -z "${REDMINE_API_KEY}" ]; then
  echo "ATTENZIONE: REDMINE_API_KEY non impostata. I workflow verso Redmine potrebbero fallire."
fi

NEXTCLOUD_USER="${NEXTCLOUD_USER:-admin}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-demo}"

# n8n: legge da .env se presente, altrimenti fallback
N8N_USER="${N8N_USER:-admin}"
# Compatibilità con variabili N8N_PASSWORD o N8N_PASS
N8N_PASS_FROM_ENV="${N8N_PASSWORD:-${N8N_PASS:-}}"
N8N_PASS="${N8N_PASS_FROM_ENV:-n8n_password}"

# --- Check prerequisiti -------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  echo "Errore: 'curl' non trovato. Installalo e riprova."
  exit 1
fi

# Funzione minimale per attendere che un endpoint HTTP risponda
wait_on_http () {
  local url="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    # accettiamo 200/302/401/403 come segnale di vita
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    if echo "$code" | grep -qE '^(200|302|401|403)$'; then
      return 0
    fi
    tries=$((tries-1))
    sleep "$sleep_s"
  done
  echo "Timeout aspettando $url"
  return 1
}

echo "Verifica disponibilità n8n… ($N8N_URL)"
wait_on_http "$N8N_URL" 60 2 || true

# --- Helpers ------------------------------------------------------------------
create_n8n_workflow() {
  local name="$1"
  local payload="$2"
  echo "Creazione workflow n8n: $name"
  # Nota: l'endpoint /workflows è mantenuto per compatibilità con la tua versione
  curl -s -X POST "$N8N_URL/workflows" \
       -u "$N8N_USER:$N8N_PASS" \
       -H "Content-Type: application/json" \
       -d "$payload" > /dev/null
}

# --- Webhook Django -> n8n ----------------------------------------------------
echo "Creazione webhook Django -> n8n per nuovi ordini…"
# Mantengo l'endpoint /webhook come nel tuo script originale
curl -s -X POST "$N8N_URL/webhook" \
     -u "$N8N_USER:$N8N_PASS" \
     -H "Content-Type: application/json" \
     -d '{
           "name": "Django_New_Order",
           "method": "POST",
           "path": "/webhook/django-new-order"
         }' > /dev/null || true

# --- Workflow: Django -> Redmine ---------------------------------------------
read -r -d '' Django_to_Redmine <<JSON
{
  "name": "Django_to_Redmine",
  "nodes": [
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "${DJANGO_URL}/api/orders",
        "responseFormat": "json"
      }
    },
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "${REDMINE_URL}/issues.json",
        "options": {
          "headers": {
            "X-Redmine-API-Key": "${REDMINE_API_KEY}"
          }
        }
      }
    }
  ]
}
JSON
create_n8n_workflow "Django_to_Redmine" "$Django_to_Redmine"

# --- Workflow: Django -> Nextcloud -------------------------------------------
read -r -d '' Django_to_Nextcloud <<JSON
{
  "name": "Django_to_Nextcloud",
  "nodes": [
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "${DJANGO_URL}/api/invoices",
        "responseFormat": "json"
      }
    },
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "${NEXTCLOUD_URL}/remote.php/dav/files/${NEXTCLOUD_USER}/Fatture/",
        "authentication": "predefinedCredentialType",
        "sendBinaryData": true
      }
    }
  ]
}
JSON
create_n8n_workflow "Django_to_Nextcloud" "$Django_to_Nextcloud"

# --- Workflow: Odoo -> Django -------------------------------------------------
read -r -d '' Odoo_to_Django <<JSON
{
  "name": "Odoo_to_Django",
  "nodes": [
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "${ODOO_URL}",
        "responseFormat": "json"
      }
    },
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "${DJANGO_URL}/api/sync/customers",
        "responseFormat": "json"
      }
    }
  ]
}
JSON
create_n8n_workflow "Odoo_to_Django" "$Odoo_to_Django"

echo "=== Integrazione API: base impostata. Personalizza i workflow in n8n. ==="
