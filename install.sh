#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Cloudetta Installer (DEMO Odoo)
# - Se SKIP_COMPOSE!=1: crea dir, build, avvia stack, migra Django, collectstatic
# - In ogni caso: popola **dati demo Odoo** in modo idempotente
# - NON si occupa di integrazioni n8n, API key Redmine o admin: li fa il bootstrap
# ============================================================================

echo "[*] Cloudetta install (DEMO Odoo)…"

# Carica .env se presente
if [ -f ".env" ]; then
  set -a
  . ./.env
  set +a
fi

# Rete docker-compose (per risolvere i nomi dei servizi tipo "odoo")
detect_compose_net() {
  docker network ls --format '{{.Name}}' | grep -E '_internal$' | head -n1
}
CNET="$(detect_compose_net || true)"

# Crea directory solo se serve
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

  echo "[*] Running Django migrations + superuser (admin/admin)"
  docker compose exec -T django python manage.py migrate
  echo "from django.contrib.auth import get_user_model; User=get_user_model(); User.objects.filter(username='admin').exists() or User.objects.create_superuser('admin','admin@example.com','admin')" \
    | docker compose exec -T django python manage.py shell

  echo "[*] Collecting static…"
  docker compose exec -T django python manage.py collectstatic --noinput
else
  echo "[*] SKIP_COMPOSE=1 → non avvio stack né eseguo step Django."
fi

# URLs interni di default
ODOO_URL="${ODOO_URL:-http://odoo:8069}"

# Attesa (se serve) che Odoo risponda
wait_on_http () {
  local url="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    code=$(docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    if echo "$code" | grep -qE '^(200|302|401|403)$'; then return 0; fi
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando $url"; return 1
}

echo "[*] Waiting Odoo…"
wait_on_http "$ODOO_URL" 120 2 || true

# Credenziali Odoo (admin/admin se non configurate)
ODOO_USER="${ODOO_USER:-admin}"
ODOO_PASS="${ODOO_PASS:-admin}"

# Percorso dello script demo lato container (comune nelle compose)
CONTAINER_DEMO="/mnt/extra-addons/demo_setup.py"
HOST_DEMO="./odoo-addons/demo_setup.py"

run_odoo_demo () {
  echo "[*] Running Odoo demo setup…"
  # prova a lanciare lo script nel container; se non c'è, copia da host
  if ! docker compose exec -T odoo bash -lc "[ -f '$CONTAINER_DEMO' ]"; then
    if [ -f "$HOST_DEMO" ]; then
      echo "[*] Copy demo_setup.py into container…"
      docker compose exec -T odoo bash -lc "mkdir -p '$(dirname "$CONTAINER_DEMO")'"
      docker cp "$HOST_DEMO" "$(docker compose ps -q odoo):$CONTAINER_DEMO"
    else
      echo "[!] demo_setup.py non trovato né nel container né nell'host ($HOST_DEMO)."
      echo "[!] Salto i dati demo Odoo."
      return 0
    fi
  fi

  # Esegui lo script demo con le credenziali Odoo disponibili in env
  docker compose exec -T odoo bash -lc "
    set -e
    export ODOO_USER='${ODOO_USER}'
    export ODOO_PASS='${ODOO_PASS}'
    export ODOO_URL='${ODOO_URL}'
    PY=\$(command -v python3 || command -v python || true)
    if [ -z \"\$PY\" ]; then
      echo '[!] python non trovato nel container Odoo' >&2
      exit 1
    fi
    \"\$PY\" -u '$CONTAINER_DEMO'
  " || echo '[!] Odoo demo setup ha restituito un errore (continuo).'
}

run_odoo_demo

echo "[*] Demo Odoo completato."
echo "[*] Done."
