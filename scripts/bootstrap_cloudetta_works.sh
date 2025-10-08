#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Cloudetta Bootstrap Installer
# - Crea/aggiorna .env con credenziali base (mail incluse)
# - Avvia (o riutilizza) docker compose
# - Attende i servizi (n8n, Nextcloud, **Redmine-DB → init → Redmine-HTTP**, Django)
# - Inizializza DB Redmine (MariaDB) creando DB/utente/permessi se mancanti
# - Imposta REDMINE_SECRET_KEY_BASE (via .env) e ricrea Redmine
# - Installa Nextcloud via occ se non installato; poi imposta/aggiorna admin
# - Django: migrate + crea admin
# - (Opzionale) Esegue install.sh per SEED DEMO Odoo senza avviare stack
# - Genera automaticamente la API key di Redmine e la salva in .env
# - Integra i workflow base n8n
# Idempotente: puoi rilanciarlo in sicurezza.
# ============================================================================

# === 0) Parametri desiderati per l’ambiente (sovrascrivibili via env) ========
DJANGO_ADMIN_USER="${DJANGO_ADMIN_USER:-admin}"
DJANGO_ADMIN_EMAIL="${DJANGO_ADMIN_EMAIL:-admin@example.com}"
DJANGO_ADMIN_PASS="${DJANGO_ADMIN_PASS:-ChangeMe!123}"

NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"
NEXTCLOUD_ADMIN_PASS="${NEXTCLOUD_ADMIN_PASS:-ChangeMe!123}"

N8N_USER="${N8N_USER:-admin}"
N8N_PASSWORD="${N8N_PASSWORD:-ChangeMe!123}"

MAIL_PROVIDER="${MAIL_PROVIDER:-sendgrid}"     # sendgrid | mailcow | smtp
MAIL_USER="${MAIL_USER:-admin@example.com}"
MAIL_PASS="${MAIL_PASS:-ChangeMe!Mail!123}"

# === helpers ================================================================
# Rete docker-compose: di solito "<folder>_internal"
detect_compose_net() {
  docker network ls --format '{{.Name}}' | grep -E '_internal$' | head -n1
}
CNET="$(detect_compose_net || true)"

curl_net() {
  # usa curl in un container collegato alla rete del compose
  local url="$1"; shift
  docker run --rm --network "${CNET:-bridge}" curlimages/curl -s "$@" "$url"
}

wait_on_http () {
  local url="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    # accettiamo 200/302/401/403/404 come "ready"
    code=$(docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    echo "[wait] $url → $code  (restano $tries tentativi)"
    if echo "$code" | grep -qE '^(200|302|401|403|404)$'; then return 0; fi
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando $url (ultimo codice: $code)"; return 1
}

# attesa MySQL/MariaDB per un servizio compose (es. redmine-db)
wait_on_mysql () {
  # $1 = service (es. redmine-db), $2 = root_pw, $3 tries, $4 sleep
  local svc="$1"; local root_pw="$2"; local tries="${3:-60}"; local sleep_s="${4:-2}"
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T "$svc" mariadb -uroot -p"$root_pw" -e "SELECT 1" >/dev/null 2>&1; then
      echo "[wait] $svc → OK (MySQL pronto)"
      return 0
    fi
    echo "[wait] $svc → not ready (restano $tries)"
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando MySQL su $svc"; return 1
}

# attesa Postgres per Django (FIX: non usare $POSTGRES_DB nell'host)
wait_on_postgres () {
  # $1 = service (es. django-db), $2 tries, $3 sleep
  local svc="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T "$svc" bash -lc 'pg_isready -h 127.0.0.1 -U "${POSTGRES_USER:-postgres}"' >/dev/null 2>&1; then
      echo "[wait] $svc → OK (Postgres pronto)"
      return 0
    fi
    echo "[wait] $svc → not ready (restano $tries)"
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando Postgres su $svc"; return 1
}


# util per appicare/aggiornare una variabile chiave nel .env (idempotente)
upsert_env_var () {
  local key="$1"; local val="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env && rm -f .env.bak || true
  else
    printf "\n%s=%s\n" "$key" "$val" >> .env
  fi
}

# === 1) Prepara .env a partire da .env.example se manca ======================
if [ ! -f .env ]; then
  echo "[bootstrap] Creo .env da .env.example"
  cp -f .env.example .env || true
  # Aggiorna chiavi principali nel nuovo .env
  tmpfile=$(mktemp)
  awk -v n8p="$N8N_PASSWORD" \
      -v mpv="$MAIL_PROVIDER" \
      -v mu="$MAIL_USER" \
      -v mp="$MAIL_PASS" '
    BEGIN{FS=OFS="="}
    $1=="DJANGO_SECRET_KEY"   {$2=sprintf("%d", systime())}
    $1=="DJANGO_DEBUG"        {$2="False"}
    $1=="N8N_PASSWORD"        {$2=n8p}
    $1=="MAIL_PROVIDER"       {$2=mpv}
    $1=="MAIL_USER"           {$2=mu}
    $1=="MAIL_PASS"           {$2=mp}
    {print}
  ' .env > "$tmpfile"
  mv "$tmpfile" .env
  chmod 600 .env || true
else
  echo "[bootstrap] Trovato .env esistente: non lo sovrascrivo"
fi

# === 1b) Assicura il secret di Redmine PRIMA del primo avvio =================
# Se REDMINE_SECRET_KEY_BASE manca, generane uno robusto (128 hex)
if ! grep -q '^REDMINE_SECRET_KEY_BASE=' .env 2>/dev/null; then
  echo "[bootstrap] Genero REDMINE_SECRET_KEY_BASE…"
  if command -v openssl >/dev/null 2>&1; then
    RSKB="$(openssl rand -hex 64)"
  else
    RSKB="$(head -c 64 /dev/urandom | od -vAn -tx1 | tr -d ' \n')"
  fi
  upsert_env_var "REDMINE_SECRET_KEY_BASE" "$RSKB"
fi

# Esporta variabili
set -a
. ./.env
# assicura override se passate da env esterno (mantengo tua logica)
N8N_PASSWORD="${N8N_PASSWORD:-$N8N_PASSWORD}"
MAIL_PROVIDER="$MAIL_PROVIDER"
MAIL_USER="$MAIL_USER"
MAIL_PASS="$MAIL_PASS"
set +a

# === 2) Avvia (o riutilizza) docker compose ==================================
if docker compose ps -q | grep -q .; then
  echo "[bootstrap] Stack già attivo: non rilancio docker compose up."
else
  echo "[bootstrap] Avvio docker compose…"
  docker compose up -d
fi

# risetta la rete ora che lo stack è partito
CNET="$(detect_compose_net || true)"

# === 3) Attesa servizi (ordine corretto con init Redmine) ====================
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
N8N_URL="${N8N_URL:-http://n8n:5678}"

echo "[bootstrap] Attendo servizi…"

# 1) n8n e nextcloud prima (ok anche se 401/403/404)
wait_on_http "$N8N_URL" 120 2 || true
wait_on_http "$NEXTCLOUD_URL" 120 2 || true

# 2) Redmine: attendo il DB, INIZIALIZZO DB/UTENTE/PERMESSI
wait_on_mysql redmine-db "${REDMINE_ROOT_PW:-root}" 120 2 || true

echo "[bootstrap] Inizializzo DB Redmine (MariaDB)…"
docker compose exec -T redmine-db mariadb -uroot -p"${REDMINE_ROOT_PW:-root}" -e "
  CREATE DATABASE IF NOT EXISTS redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS 'redmine'@'%' IDENTIFIED BY '${REDMINE_DB_PASSWORD}';
  GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'%';
  FLUSH PRIVILEGES;
" || echo "WARN: inizializzazione Redmine DB fallita (continua lo stesso)."

# Riavvio/ricreo Redmine dopo che .env contiene REDMINE_SECRET_KEY_BASE
echo "[bootstrap] Riavvio Redmine con SECRET da .env…"
docker compose up -d --force-recreate --no-deps redmine || true

# Non forziamo migrazioni: le fa l'entrypoint. Attendi HTTP.
wait_on_http "$REDMINE_URL" 180 2 || true

# 3) Django: DB pronto → migrate → superuser
wait_on_postgres django-db 120 2 || true

# Migrate con retry soft (se Postgres ci mette un attimo)
for i in $(seq 1 10); do
  if docker compose exec -T django bash -lc 'python manage.py migrate --noinput'; then
    break
  fi
  sleep 2
done

# === 4) Configurazioni applicative ===========================================

# 4a) Django: crea/aggiorna superuser
echo "[bootstrap] Configuro Django superuser…"
docker compose exec -T django python - <<'PY' || true
import os, sys
os.environ.setdefault("DJANGO_SETTINGS_MODULE", os.environ.get("DJANGO_SETTINGS_MODULE","config.settings"))
try:
    import django; django.setup()
    from django.contrib.auth import get_user_model
    U = get_user_model()
    username = os.environ.get("DJANGO_ADMIN_USER","admin")
    email    = os.environ.get("DJANGO_ADMIN_EMAIL","admin@example.com")
    password = os.environ.get("DJANGO_ADMIN_PASS","ChangeMe!123")
    u, created = U.objects.get_or_create(username=username, defaults={
        "email": email,
        "is_superuser": True,
        "is_staff": True,
    })
    u.set_password(password); u.save()
    print("Django admin pronto:", u.username)
except Exception as e:
    print("WARN Django:", e, file=sys.stderr)
PY

# 4b) Nextcloud: installa se necessario; altrimenti reset password admin
echo "[bootstrap] Configuro/Installo Nextcloud…"
docker compose exec -T nextcloud bash -lc '
set -e
PHP=php
if [ ! -f config/config.php ] || ! grep -q "installed..=>..true" config/config.php 2>/dev/null; then
  echo "Nextcloud non installato: eseguo occ maintenance:install…"
  runuser -u www-data -- $PHP occ maintenance:install \
    --database "mysql" \
    --database-host "$MYSQL_HOST" \
    --database-name "$MYSQL_DATABASE" \
    --database-user "$MYSQL_USER" \
    --database-pass "$MYSQL_PASSWORD" \
    --admin-user "'"${NEXTCLOUD_ADMIN_USER}"'" \
    --admin-pass "'"${NEXTCLOUD_ADMIN_PASS}"'"
else
  echo "Nextcloud già installato: sync impostazioni admin…"
  export OC_PASS="'"${NEXTCLOUD_ADMIN_PASS}"'"
  runuser -u www-data -- $PHP occ user:resetpassword --password-from-env "'"${NEXTCLOUD_ADMIN_USER}"'" || true
fi
' || echo "WARN: configurazione Nextcloud non riuscita (occ)."

# 4c) (Opzionale) Seeds DEMO Odoo (senza comporre lo stack)
if [ -f "./install.sh" ]; then
  echo "[bootstrap] Eseguo install.sh per i dati demo Odoo…"
  SKIP_COMPOSE=1 \
  DEMO=1 \
  DJANGO_USER="${DJANGO_ADMIN_USER}" \
  DJANGO_PASS="${DJANGO_ADMIN_PASS}" \
  NEXTCLOUD_USER="${NEXTCLOUD_ADMIN_USER}" \
  NEXTCLOUD_PASS="${NEXTCLOUD_ADMIN_PASS}" \
  N8N_USER="${N8N_USER}" \
  N8N_PASSWORD="${N8N_PASSWORD}" \
  REDMINE_API_KEY="${REDMINE_API_KEY:-}" \
  bash ./install.sh || echo "WARN: install.sh ha dato errore; continuo comunque."
else
  echo "[bootstrap] install.sh non trovato: salto seed demo."
fi

# 4d) Redmine: genera API key admin e salvala in .env
echo "[bootstrap] Genero API key Redmine…"
REDMINE_KEY_OUTPUT=$(docker compose exec -T redmine bash -lc '
  if command -v bundle >/dev/null 2>&1; then
    bundle exec rails runner "
      u = User.find_by_login(\"admin\") || User.find(1)
      if u.nil?
        puts \"ERR: admin non trovato\"
      else
        if u.api_key.nil?
          t = Token.create(user: u, action: \"api\")
          puts \"API_KEY=#{t.value}\"
        else
          puts \"API_KEY=#{u.api_key}\"
        end
      end
    "
  else
    echo "ERR: rails/bundle non disponibili nel container"
  fi
' 2>/dev/null || true)

REDMINE_API_KEY_GENERATED="$(echo "$REDMINE_KEY_OUTPUT" | sed -n 's/^API_KEY=//p' | tr -d '\r\n')"

if [ -n "${REDMINE_API_KEY_GENERATED}" ]; then
  echo "[bootstrap] API key Redmine ottenuta: ${REDMINE_API_KEY_GENERATED:0:6}********"
  upsert_env_var "REDMINE_API_KEY" "$REDMINE_API_KEY_GENERATED"
  export REDMINE_API_KEY="$REDMINE_API_KEY_GENERATED"
else
  echo "[bootstrap] ATTENZIONE: impossibile ottenere la API key di Redmine in automatico."
  echo "            Inseriscila manualmente in .env (REDMINE_API_KEY) e rilancia."
fi

# === 5) Integrazioni n8n (inline) ============================================
echo "[bootstrap] Configuro integrazioni n8n…"

# Endpoints interni (come compose)
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
ODOO_URL="${ODOO_URL:-http://odoo:8069}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
N8N_URL="${N8N_URL:-http://n8n:5678}"

# Credenziali con default sensati
DJANGO_USER="${DJANGO_USER:-$DJANGO_ADMIN_USER}"
DJANGO_PASS="${DJANGO_PASS:-$DJANGO_ADMIN_PASS}"
ODOO_USER="${ODOO_USER:-admin}"
ODOO_PASS="${ODOO_PASS:-admin}"
NEXTCLOUD_USER="${NEXTCLOUD_USER:-$NEXTCLOUD_ADMIN_USER}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-$NEXTCLOUD_ADMIN_PASS}"
N8N_USER="${N8N_USER:-$N8N_USER}"
N8N_PASS_FROM_ENV="${N8N_PASSWORD:-${N8N_PASS:-}}"
N8N_PASS="${N8N_PASS_FROM_ENV:-$N8N_PASSWORD}"

# Attendo n8n
wait_on_http "$N8N_URL" 60 2 || true

create_n8n_workflow() {
  local name="$1"; local payload="$2"
  echo "Creazione workflow n8n: $name"
  curl_net "$N8N_URL/workflows" -X POST -u "$N8N_USER:$N8N_PASS" -H "Content-Type: application/json" -d "$payload" > /dev/null || true
}

# Webhook Django -> n8n (compat)
echo "Creazione webhook Django -> n8n per nuovi ordini…"
curl_net "$N8N_URL/webhook" -X POST -u "$N8N_USER:$N8N_PASS" -H "Content-Type: application/json" -d '{
  "name": "Django_New_Order",
  "method": "POST",
  "path": "/webhook/django-new-order"
}' > /dev/null || true

# Workflow: Django -> Redmine
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
            "X-Redmine-API-Key": "${REDMINE_API_KEY:-}"
          }
        }
      }
    }
  ]
}
JSON
create_n8n_workflow "Django_to_Redmine" "$Django_to_Redmine"

# Workflow: Django -> Nextcloud
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

# Workflow: Odoo -> Django
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

echo "[bootstrap] Integrazioni n8n: base impostata."

# === 6) Riepilogo =============================================================
cat <<INFO

[bootstrap] Completato.

Accessi interni:
- Django   → $DJANGO_URL   | utente: $DJANGO_ADMIN_USER
- Redmine  → $REDMINE_URL  | utente: admin (password da UI)
- Nextcloud→ $NEXTCLOUD_URL | utente: $NEXTCLOUD_ADMIN_USER
- n8n      → $N8N_URL      | utente: $N8N_USER

Mail (.env):
- MAIL_PROVIDER=$MAIL_PROVIDER
- MAIL_USER=$MAIL_USER
- MAIL_PASS=******

INFO
