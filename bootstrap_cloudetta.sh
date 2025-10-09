#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Cloudetta Bootstrap Installer (versione completa, fix Odoo + Redmine env)
# - Prepara/aggiorna .env
# - Avvia/riutilizza docker compose
# - Attende i servizi (n8n, Nextcloud, Redmine-DB → init → Redmine-HTTP, Django)
# - Nextcloud: install + trusted_domains + admin
# - Django: migrate + admin
# - Redmine: DB init + secret + sync admin + API key
# - Odoo: master password + crea DB con demo (solo se manca)
# - Integrazioni n8n (base)
# - Stampa credenziali/URL
# - Idempotente
# ============================================================================

# === 0) Parametri desiderati per l’ambiente (sovrascrivibili via env) ========
DJANGO_ADMIN_USER="${DJANGO_ADMIN_USER:-admin}"
DJANGO_ADMIN_EMAIL="${DJANGO_ADMIN_EMAIL:-admin@example.com}"
DJANGO_ADMIN_PASS="${DJANGO_ADMIN_PASS:-ChangeMe!123}"

NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"
NEXTCLOUD_ADMIN_PASS="${NEXTCLOUD_ADMIN_PASS:-ChangeMe!123}"

N8N_USER="${N8N_USER:-admin}"
N8N_PASSWORD="${N8N_PASSWORD:-ChangeMe!123}"

MAIL_PROVIDER="${MAIL_PROVIDER:-sendgrid}"
MAIL_USER="${MAIL_USER:-admin@example.com}"
MAIL_PASS="${MAIL_PASS:-ChangeMe!Mail!123}"

# === helpers ================================================================
detect_compose_net() { docker network ls --format '{{.Name}}' | grep -E '_internal$' | head -n1; }
CNET="$(detect_compose_net || true)"

curl_net() { local url="$1"; shift; docker run --rm --network "${CNET:-bridge}" curlimages/curl -s "$@" "$url"; }

wait_on_http () {
  local url="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    code=$(docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    echo "[wait] $url → $code  (restano $tries tentativi)"
    # accettiamo 200/301/302/303/401/403/404
    if echo "$code" | grep -qE '^(200|30[123]|401|403|404)$'; then return 0; fi
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando $url (ultimo codice: $code)"; return 1
}

wait_on_mysql () {
  local svc="$1"; local root_pw="$2"; local tries="${3:-60}"; local sleep_s="${4:-2}"
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T "$svc" mariadb -uroot -p"$root_pw" -e "SELECT 1" >/dev/null 2>&1; then
      echo "[wait] $svc → OK (MySQL pronto)"; return 0; fi
    echo "[wait] $svc → not ready (restano $tries)"; tries=$((tries-1)); sleep "$sleep_s"
  done; echo "Timeout aspettando MySQL su $svc"; return 1
}

wait_on_postgres () {
  local svc="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T "$svc" bash -lc 'pg_isready -h 127.0.0.1 -U "${POSTGRES_USER:-postgres}"' >/dev/null 2>&1; then
      echo "[wait] $svc → OK (Postgres pronto)"; return 0; fi
    echo "[wait] $svc → not ready (restano $tries)"; tries=$((tries-1)); sleep "$sleep_s"
  done; echo "Timeout aspettando Postgres su $svc"; return 1
}

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

# === 1b) Unifica credenziali (ADMIN_*) e propaga =============================
: "${ADMIN_USER:=$DJANGO_ADMIN_USER}"
: "${ADMIN_PASS:=$DJANGO_ADMIN_PASS}"
: "${ADMIN_EMAIL:=$DJANGO_ADMIN_EMAIL}"
upsert_env_var "ADMIN_USER" "$ADMIN_USER"
upsert_env_var "ADMIN_PASS" "$ADMIN_PASS"
upsert_env_var "ADMIN_EMAIL" "$ADMIN_EMAIL"

grep -q '^DJANGO_ADMIN_USER=' .env 2>/dev/null || upsert_env_var "DJANGO_ADMIN_USER" "$ADMIN_USER"
grep -q '^DJANGO_ADMIN_EMAIL=' .env 2>/dev/null || upsert_env_var "DJANGO_ADMIN_EMAIL" "$ADMIN_EMAIL"
grep -q '^DJANGO_ADMIN_PASS=' .env 2>/dev/null || upsert_env_var "DJANGO_ADMIN_PASS" "$ADMIN_PASS"
grep -q '^NEXTCLOUD_ADMIN_USER=' .env 2>/dev/null || upsert_env_var "NEXTCLOUD_ADMIN_USER" "$ADMIN_USER"
grep -q '^NEXTCLOUD_ADMIN_PASS=' .env 2>/dev/null || upsert_env_var "NEXTCLOUD_ADMIN_PASS" "$ADMIN_PASS"
grep -q '^N8N_PASSWORD=' .env 2>/dev/null || upsert_env_var "N8N_PASSWORD" "$ADMIN_PASS"

# === 1c) Secret Redmine PRIMA del primo avvio =================================
if ! grep -q '^REDMINE_SECRET_KEY_BASE=' .env 2>/dev/null || grep -q '^REDMINE_SECRET_KEY_BASE=$' .env 2>/dev/null; then
  echo "[bootstrap] Genero REDMINE_SECRET_KEY_BASE…"
  if command -v openssl >/dev/null 2>&1; then
    RSKB="$(openssl rand -hex 64)"
  else
    RSKB="$(head -c 64 /dev/urandom | od -vAn -tx1 | tr -d ' \n')"
  fi
  upsert_env_var "REDMINE_SECRET_KEY_BASE" "$RSKB"
fi

# === 1d) Default Nextcloud/Odoo =============================================
grep -q '^TRUSTED_DOMAINS=' .env 2>/dev/null || upsert_env_var "TRUSTED_DOMAINS" "localhost,127.0.0.1,nextcloud,nextcloud.localhost"
grep -q '^ODOO_DB=' .env 2>/dev/null || upsert_env_var "ODOO_DB" "cloudetta"
grep -q '^ODOO_MASTER_PASSWORD=' .env 2>/dev/null || upsert_env_var "ODOO_MASTER_PASSWORD" "$ADMIN_PASS"
grep -q '^ODOO_DEMO=' .env 2>/dev/null || upsert_env_var "ODOO_DEMO" "true"
grep -q '^ODOO_LANG=' .env 2>/dev/null || upsert_env_var "ODOO_LANG" "it_IT"

# Esporta variabili
set -a
. ./.env
set +a

# === 2) Avvia (o riutilizza) docker compose =================================
if docker compose ps -q | grep -q .; then
  echo "[bootstrap] Stack già attivo: non rilancio docker compose up."
else
  echo "[bootstrap] Avvio docker compose…"
  docker compose up -d
fi
CNET="$(detect_compose_net || true)"

# === 3) Attesa servizi (ordine corretto) =====================================
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
ODOO_URL="${ODOO_URL:-http://odoo:8069}"
N8N_URL="${N8N_URL:-http://n8n:5678}"

echo "[bootstrap] Attendo servizi…"
wait_on_http "$N8N_URL" 120 2 || true
wait_on_http "$NEXTCLOUD_URL" 120 2 || true

wait_on_mysql redmine-db "${REDMINE_ROOT_PW:-root}" 120 2 || true

echo "[bootstrap] Inizializzo DB Redmine (MariaDB)…"
docker compose exec -T redmine-db mariadb -uroot -p"${REDMINE_ROOT_PW:-root}" -e "
  CREATE DATABASE IF NOT EXISTS redmine CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS 'redmine'@'%' IDENTIFIED BY '${REDMINE_DB_PASSWORD}';
  GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'%';
  FLUSH PRIVILEGES;
" || echo "WARN: inizializzazione Redmine DB fallita (continua lo stesso)."

echo "[bootstrap] Riavvio Redmine con SECRET da .env…"
docker compose up -d --force-recreate --no-deps redmine || true
wait_on_http "$REDMINE_URL" 180 2 || true

# Django DB → migrate → superuser
wait_on_postgres django-db 120 2 || true
for i in $(seq 1 10); do
  if docker compose exec -T django bash -lc 'python manage.py migrate --noinput'; then
    break
  fi
  sleep 2
done

# === 4) Configurazioni applicative ===========================================
# 4a) Django superuser
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
    u, created = U.objects.get_or_create(username=username, defaults={"email": email,"is_superuser": True,"is_staff": True})
    u.set_password(password); u.save()
    print("Django admin pronto:", u.username)
except Exception as e:
    print("WARN Django:", e, file=sys.stderr)
PY

# 4b) Nextcloud: install + reset pass + trusted_domains
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

# trusted_domains da env TRUSTED_DOMAINS
idx=0
for d in '"${TRUSTED_DOMAINS//,/ }"'; do
  runuser -u www-data -- $PHP occ config:system:set trusted_domains $idx --value "$d"
  idx=$((idx+1))
done

# overwrite.cli.url se PUBLIC_DOMAIN presente
if [ -n "'"${PUBLIC_DOMAIN:-}"'" ]; then
  runuser -u www-data -- $PHP occ config:system:set overwrite.cli.url --value "https://'"${PUBLIC_DOMAIN}"'"
fi
' || echo "WARN: configurazione Nextcloud non riuscita (occ)."

# 4c) Odoo: master password + crea DB con demo (solo se manca)
echo "[bootstrap] Configuro Odoo (master password + DB demo)…"
docker compose exec -T odoo bash -lc '
set -e
install -m 600 /dev/stdin /var/lib/odoo/.odoorc <<EOF
[options]
admin_passwd = '"$ODOO_MASTER_PASSWORD"'
EOF
' || true

docker compose restart odoo >/dev/null 2>&1 || true
# Odoo su "/" fa redirect 303: controlliamo la pagina login che risponde 200
wait_on_http "${ODOO_URL%/}/web/login" 120 2 || true

# Verifica DB esistenti via JSON-RPC
DBS_RAW="$(docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":{}}" \
  "${ODOO_URL%/}/web/database/list" || true)"

if echo "$DBS_RAW" | grep -q "\"${ODOO_DB}\""; then
  echo "[bootstrap] Odoo DB '${ODOO_DB}' già presente: non ricreo."
else
  echo "[bootstrap] Creo Odoo DB '${ODOO_DB}' (demo=${ODOO_DEMO})…"
  docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -X POST \
    "${ODOO_URL%/}/web/database/create" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "master_pwd=${ODOO_MASTER_PASSWORD}" \
    --data-urlencode "name=${ODOO_DB}" \
    --data-urlencode "lang=${ODOO_LANG:-en_US}" \
    --data-urlencode "login=${ADMIN_EMAIL}" \
    --data-urlencode "password=${ADMIN_PASS}" \
    --data-urlencode "phone=" \
    --data-urlencode "country_code=" \
    --data-urlencode "demo=${ODOO_DEMO}" >/dev/null || true
fi

# 4d) Redmine: sincronizza admin (pass/email) e ottieni API key
echo "[bootstrap] Imposto password/email admin Redmine…"
docker compose exec -T \
  -e ADMIN_EMAIL="$ADMIN_EMAIL" \
  -e ADMIN_PASS="$ADMIN_PASS" \
  redmine bash -lc '
bundle exec rails runner "
  email = ENV[\"ADMIN_EMAIL\"]
  email = \"admin@example.com\" if email.nil? || email.strip.empty?
  pass  = ENV[\"ADMIN_PASS\"]
  pass  = \"ChangeMe!123\" if pass.nil? || pass.strip.empty?

  u = User.find_by_login(\"admin\")
  if u
    u.password = pass; u.password_confirmation = pass
    u.mail = email; u.must_change_passwd = false
    u.save!
    puts \"Redmine admin aggiornato: #{u.mail}\"
  else
    puts \"ERRORE: utente admin non trovato\"
  end
"
' || true

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
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
ODOO_URL="${ODOO_URL:-http://odoo:8069}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
N8N_URL="${N8N_URL:-http://n8n:5678}"

DJANGO_USER="${DJANGO_USER:-$DJANGO_ADMIN_USER}"
DJANGO_PASS="${DJANGO_PASS:-$DJANGO_ADMIN_PASS}"
ODOO_USER="${ODOO_USER:-admin}"
ODOO_PASS="${ODOO_PASS:-admin}"
NEXTCLOUD_USER="${NEXTCLOUD_USER:-$NEXTCLOUD_ADMIN_USER}"
NEXTCLOUD_PASS="${NEXTCLOUD_PASS:-$NEXTCLOUD_ADMIN_PASS}"
N8N_USER="${N8N_USER:-$N8N_USER}"
N8N_PASS_FROM_ENV="${N8N_PASSWORD:-${N8N_PASS:-}}"
N8N_PASS="${N8N_PASS_FROM_ENV:-$N8N_PASSWORD}"

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

Django_to_Redmine=$(cat <<JSON
{
  "name": "Django_to_Redmine",
  "nodes": [
    {"type":"HTTP Request","parameters":{"url":"${DJANGO_URL}/api/orders","responseFormat":"json"}},
    {"type":"HTTP Request","parameters":{"url":"${REDMINE_URL}/issues.json","options":{"headers":{"X-Redmine-API-Key":"${REDMINE_API_KEY:-}"}}}}
  ]
}
JSON
)
create_n8n_workflow "Django_to_Redmine" "$Django_to_Redmine"

Django_to_Nextcloud=$(cat <<JSON
{
  "name": "Django_to_Nextcloud",
  "nodes": [
    {"type":"HTTP Request","parameters":{"url":"${DJANGO_URL}/api/invoices","responseFormat":"json"}},
    {"type":"HTTP Request","parameters":{"url":"${NEXTCLOUD_URL}/remote.php/dav/files/${NEXTCLOUD_USER}/Fatture/","authentication":"predefinedCredentialType","sendBinaryData":true}}
  ]
}
JSON
)
create_n8n_workflow "Django_to_Nextcloud" "$Django_to_Nextcloud"

Odoo_to_Django=$(cat <<JSON
{
  "name": "Odoo_to_Django",
  "nodes": [
    {"type":"HTTP Request","parameters":{"url":"${ODOO_URL}","responseFormat":"json"}},
    {"type":"HTTP Request","parameters":{"url":"${DJANGO_URL}/api/sync/customers","responseFormat":"json"}}
  ]
}
JSON
)
create_n8n_workflow "Odoo_to_Django" "$Odoo_to_Django"

echo "[bootstrap] Ingegrazioni n8n: base impostata."

# === 6) Riepilogo =============================================================
cat <<INFO

[bootstrap] Completato.

Credenziali amministratore (unificate):
- USER:   ${ADMIN_USER}
- PASS:   ${ADMIN_PASS}
- EMAIL:  ${ADMIN_EMAIL}

Accessi interni:
- Django     → ${DJANGO_URL}           | login: ${DJANGO_ADMIN_USER}/${DJANGO_ADMIN_PASS}
- Redmine    → ${REDMINE_URL}          | login: admin/${ADMIN_PASS}
- Nextcloud  → ${NEXTCLOUD_URL}        | login: ${NEXTCLOUD_ADMIN_USER}/${NEXTCLOUD_ADMIN_PASS}
- Odoo       → ${ODOO_URL}             | login: ${ADMIN_EMAIL}/${ADMIN_PASS}  (DB: ${ODOO_DB})
- n8n        → ${N8N_URL}              | BasicAuth: ${N8N_USER}/${N8N_PASS}
- DokuWiki   → http://wiki.localhost   | (consigliato BasicAuth in Caddy)

Nextcloud:
- trusted_domains = ${TRUSTED_DOMAINS}
- overwrite.cli.url = ${PUBLIC_DOMAIN:-<non impostato>}

Redmine:
- API key (REDMINE_API_KEY in .env): ${REDMINE_API_KEY:-<non disponibile>}

Mail (.env):
- MAIL_PROVIDER=$MAIL_PROVIDER
- MAIL_USER=$MAIL_USER
- MAIL_PASS=******

INFO
