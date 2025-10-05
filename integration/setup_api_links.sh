#!/usr/bin/env bash
set -e

echo "=== Configurazione integrazione API tra sistemi ==="

DJANGO_URL="http://django:8000"
ODOO_URL="http://odoo:8069"
REDMINE_URL="http://redmine:3000"
NEXTCLOUD_URL="http://nextcloud:80"
N8N_URL="http://n8n:5678"

DJANGO_USER="${DJANGO_USER:-admin}"
DJANGO_PASS="${DJANGO_PASS:-admin}"

ODOO_USER="${ODOO_USER:-admin}"
ODOO_PASS="${ODOO_PASS:-admin}"

# Nota: per Redmine, inserisci manualmente la API key se non disponibile come file.
REDMINE_API_KEY="${REDMINE_API_KEY:-your_redmine_api_key}"

NEXTCLOUD_USER="${NEXTCLOUD_USER:-admin}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-demo}"

N8N_USER="admin"
N8N_PASS=$(grep N8N_PASSWORD .env | cut -d= -f2)

create_n8n_workflow() {
  local name=$1
  local payload=$2
  echo "Creazione workflow n8n: $name"
  curl -s -X POST "$N8N_URL/workflows"     -u "$N8N_USER:$N8N_PASS"     -H "Content-Type: application/json"     -d "$payload" > /dev/null
}

echo "Creazione webhook Django -> n8n per nuovi ordini..."
curl -s -X POST "$N8N_URL/webhook"   -u "$N8N_USER:$N8N_PASS"   -H "Content-Type: application/json"   -d '{
        "name": "Django_New_Order",
        "method": "POST",
        "path": "/webhook/django-new-order"
      }' > /dev/null

Django_to_Redmine='{
  "name": "Django_to_Redmine",
  "nodes": [
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "'"$DJANGO_URL"'/api/orders",
        "responseFormat": "json"
      }
    },
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "'"$REDMINE_URL"'/issues.json",
        "options": {
          "headers": {
            "X-Redmine-API-Key": "'"$REDMINE_API_KEY"'"
          }
        }
      }
    }
  ]
}'
create_n8n_workflow "Django_to_Redmine" "$Django_to_Redmine"

Django_to_Nextcloud='{
  "name": "Django_to_Nextcloud",
  "nodes": [
    {
      "type": "HTTP Request",
      "parameters": { "url": "'"$DJANGO_URL"'/api/invoices", "responseFormat": "json" }
    },
    {
      "type": "HTTP Request",
      "parameters": {
        "url": "'"$NEXTCLOUD_URL"'/remote.php/dav/files/'"$NEXTCLOUD_USER"'/Fatture/",
        "authentication": "predefinedCredentialType",
        "sendBinaryData": true
      }
    }
  ]
}'
create_n8n_workflow "Django_to_Nextcloud" "$Django_to_Nextcloud"

Odoo_to_Django='{
  "name": "Odoo_to_Django",
  "nodes": [
    { "type": "HTTP Request", "parameters": { "url": "'"$ODOO_URL"'", "responseFormat": "json" } },
    { "type": "HTTP Request", "parameters": { "url": "'"$DJANGO_URL"'/api/sync/customers", "responseFormat": "json" } }
  ]
}'
create_n8n_workflow "Odoo_to_Django" "$Odoo_to_Django"

echo "=== Integrazione API: base impostata. Personalizza i workflow in n8n. ==="
