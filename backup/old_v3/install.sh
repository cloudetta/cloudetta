#!/usr/bin/env bash
# Portabile: abilita pipefail solo se disponibile
set -eu
( set -o pipefail ) 2>/dev/null && set -o pipefail

# ============================================================================
# Cloudetta install (DEMO Odoo)
# - Se SKIP_COMPOSE!=1: crea dir, build, avvia stack, migra Django, collectstatic
# - In ogni caso: popola dati demo Odoo in modo idempotente
# - NON fa n8n/Redmine admin/Nextcloud: lo fa il bootstrap
# ============================================================================

echo "[*] Cloudetta install (DEMO Odoo)…"

# Carica .env se presente
if [ -f ".env" ]; then
  set -a
  . ./.env
  set +a
fi

# Helper: rete docker-compose interna (es: <folder>_internal)
detect_compose_net() {
  docker network ls --format '{{.Name}}' | grep -E '_internal$' | head -n1
}
CNET="$(detect_compose_net || true)"

curl_net() {
  local url="$1"; shift
  docker run --rm --network "${CNET:-bridge}" curlimages/curl -s "$@" "$url"
}

wait_on_http () {
  local url="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    code=$(curl_net "$url" -o /dev/null -w "%{http_code}" || true)
    if echo "$code" | grep -qE '^(200|30[123]|401|403)$'; then return 0; fi
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando $url"; return 1
}

if [ "${SKIP_COMPOSE:-}" != "1" ]; then
  echo "[*] Creating data directories…"
  mkdir -p caddy odoo-addons django django/static django/media backups integration backup
  mkdir -p data/{django-db-data,odoo-data,postgres-odoo-data,redis-data,redmine-data,redmine-db-data,nextcloud-data,nextcloud-db-data,n8n-data,dokuwiki-data}

  if [ ! -f ".env" ]; then
    echo "[*] Generating .env from .env.example (remember to edit secrets)"
    cp .env.example .env
  fi

  echo "[*] Building images…"
  docker compose build

  echo "[*] Starting stack…"
  docker compose up -d

  echo "[*] Running Django migrations + superuser"
  docker compose exec -T django bash -lc 'python manage.py migrate --noinput && python - <<PY
from django.contrib.auth import get_user_model
U=get_user_model()
u,created=U.objects.get_or_create(username=\"${DJANGO_ADMIN_USER:-admin}\",defaults={\"email\":\"${DJANGO_ADMIN_EMAIL:-admin@example.com}\",\"is_superuser\":True,\"is_staff\":True})
u.set_password(\"${DJANGO_ADMIN_PASS:-admin}\"); u.save()
print(\"Django admin pronto\", u.username)
PY'

  echo "[*] Collecting static…"
  docker compose exec -T django bash -lc 'python manage.py collectstatic --noinput || true'
else
  echo "[*] SKIP_COMPOSE=1 → non avvio stack né eseguo step Django."
fi

# URLs interni
ODOO_URL="${ODOO_URL:-http://odoo:8069}"

echo "[*] Waiting Odoo…"
wait_on_http "$ODOO_URL" 120 2 || true

# Credenziali Odoo
ODOO_USER="${ODOO_USER:-admin}"
ODOO_PASS="${ODOO_PASS:-admin}"

# Script demo
CONTAINER_DEMO="/mnt/extra-addons/demo_setup.py"
HOST_DEMO="./odoo-addons/demo_setup.py"

run_odoo_demo () {
  echo "[*] Running Odoo demo setup…"
  if ! docker compose exec -T odoo bash -lc "[ -f '$CONTAINER_DEMO' ]"; then
    if [ -f "$HOST_DEMO" ]; then
      echo "[*] Copy demo_setup.py into container…"
      docker cp "$HOST_DEMO" "$(docker compose ps -q odoo):$CONTAINER_DEMO"
    else
      echo "[!] demo_setup.py non trovato ($HOST_DEMO). Salto i dati demo Odoo."
      return 0
    fi
  fi

  docker compose exec -T odoo bash -lc "
    export ODOO_USER='${ODOO_USER}';
    export ODOO_PASS='${ODOO_PASS}';
    export ODOO_URL='${ODOO_URL}';
    python3 -u '$CONTAINER_DEMO'
  " || echo '[!] Odoo demo setup ha restituito un errore (continuo).'
}

run_odoo_demo

echo "[*] Demo Odoo completato."
echo "[*] Done."
