#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Cloudetta Bootstrap Installer (versione completa, uniformità ENV + Mautic)
# - Prepara/aggiorna .env
# - Avvia/riutilizza docker compose
# - Attende i servizi (n8n, Nextcloud, Redmine-DB → init → Redmine-HTTP, Django)
# - Nextcloud: install + trusted_domains + admin
# - Django: migrate + admin
# - Redmine: DB init + secret + sync admin + API key
# - Odoo: master password + crea DB con demo (solo se manca)
# - Mautic: install CLI (se disponibile), migrazioni, admin, site_url
# - Integrazioni n8n (base)
# - Stampa credenziali/URL
# - Idempotente
# ============================================================================

# === helpers ================================================================
detect_compose_net() { docker network ls --format '{{.Name}}' | grep -E '_internal$' | head -n1; }
CNET="$(detect_compose_net || true)"

curl_net() { # curl containerizzato (no dipendenze host), silenzioso
  local url="$1"; shift
  docker run --rm --network "${CNET:-bridge}" curlimages/curl -s "$@" "$url"
}

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

# === 1) Prepara .env (se manca) e applica default SOLO dove vuoto ============
if [ ! -f .env ]; then
  echo "[bootstrap] Creo .env da .env.example"
  cp -f .env.example .env || true
fi

# aggiorna alcuni default nel file (secret key, debug, mail/n8n) SOLO se vuoti
tmpfile=$(mktemp)
awk -v n8p="${N8N_PASSWORD:-}" -v mpv="${MAIL_PROVIDER:-}" -v mu="${MAIL_USER:-}" -v mp="${MAIL_PASS:-}" '
  BEGIN{FS=OFS="="}
  $1=="DJANGO_SECRET_KEY" && ($2=="" || $2=="dev_change_me") {$2=sprintf("%d", systime())}
  $1=="DJANGO_DEBUG"  && $2=="" {$2="False"}
  $1=="N8N_PASSWORD"  && n8p!="" {$2=n8p}
  $1=="MAIL_PROVIDER" && mpv!="" {$2=mpv}
  $1=="MAIL_USER"     && mu!=""  {$2=mu}
  $1=="MAIL_PASS"     && mp!=""  {$2=mp}
  {print}
' .env > "$tmpfile" && mv "$tmpfile" .env
chmod 600 .env || true

# carichiamo .env come sorgente di verità
set -a; . ./.env; set +a

# === 1b) Obbligatorie: devono essere presenti in .env =======================
: "${ADMIN_USER:?metti ADMIN_USER in .env}"
: "${ADMIN_PASS:?metti ADMIN_PASS in .env}"
: "${ADMIN_EMAIL:?metti ADMIN_EMAIL in .env}"

# Derivati applicativi: se mancano in .env, li generiamo dai valori unificati
[ -z "${DJANGO_ADMIN_USER:-}" ]  && upsert_env_var "DJANGO_ADMIN_USER"  "$ADMIN_USER"  && export DJANGO_ADMIN_USER="$ADMIN_USER"
[ -z "${DJANGO_ADMIN_EMAIL:-}" ] && upsert_env_var "DJANGO_ADMIN_EMAIL" "$ADMIN_EMAIL" && export DJANGO_ADMIN_EMAIL="$ADMIN_EMAIL"
[ -z "${DJANGO_ADMIN_PASS:-}" ]  && upsert_env_var "DJANGO_ADMIN_PASS"  "$ADMIN_PASS"  && export DJANGO_ADMIN_PASS="$ADMIN_PASS"

[ -z "${NEXTCLOUD_ADMIN_USER:-}" ] && upsert_env_var "NEXTCLOUD_ADMIN_USER" "$ADMIN_USER" && export NEXTCLOUD_ADMIN_USER="$ADMIN_USER"
[ -z "${NEXTCLOUD_ADMIN_PASS:-}" ] && upsert_env_var "NEXTCLOUD_ADMIN_PASS" "$ADMIN_PASS" && export NEXTCLOUD_ADMIN_PASS="$ADMIN_PASS"

# n8n: usa gli stessi dell’admin unificato se non specificato
[ -z "${N8N_USER:-}" ]     && upsert_env_var "N8N_USER" "$ADMIN_USER" && export N8N_USER="$ADMIN_USER"
[ -z "${N8N_PASSWORD:-}" ] && upsert_env_var "N8N_PASSWORD" "$ADMIN_PASS" && export N8N_PASSWORD="$ADMIN_PASS"

# Odoo: master password = ADMIN_PASS (se mancante), DB defaults
[ -z "${ODOO_MASTER_PASSWORD:-}" ] && upsert_env_var "ODOO_MASTER_PASSWORD" "$ADMIN_PASS" && export ODOO_MASTER_PASSWORD="$ADMIN_PASS"
[ -z "${ODOO_DB:-}" ]              && upsert_env_var "ODOO_DB" "cloudetta" && export ODOO_DB="cloudetta"
[ -z "${ODOO_DEMO:-}" ]            && upsert_env_var "ODOO_DEMO" "true"     && export ODOO_DEMO="true"
[ -z "${ODOO_LANG:-}" ]            && upsert_env_var "ODOO_LANG" "it_IT"    && export ODOO_LANG="it_IT"

# Nextcloud trusted domains default (se mancano)
[ -z "${TRUSTED_DOMAINS:-}" ] && upsert_env_var "TRUSTED_DOMAINS" "localhost,127.0.0.1,nextcloud,nextcloud.localhost" && export TRUSTED_DOMAINS="localhost,127.0.0.1,nextcloud,nextcloud.localhost"

# Redmine secret PRIMA dell’avvio, se manca
if [ -z "${REDMINE_SECRET_KEY_BASE:-}" ]; then
  echo "[bootstrap] Genero REDMINE_SECRET_KEY_BASE…"
  if command -v openssl >/dev/null 2>&1; then
    RSKB="$(openssl rand -hex 64)"
  else
    RSKB="$(head -c 64 /dev/urandom | od -vAn -tx1 | tr -d ' \n')"
  fi
  upsert_env_var "REDMINE_SECRET_KEY_BASE" "$RSKB"
  export REDMINE_SECRET_KEY_BASE="$RSKB"
fi

# Mautic: default sicuri se mancano (puoi sovrascrivere in .env)
[ -z "${MAUTIC_DB_HOST:-}" ]     && upsert_env_var "MAUTIC_DB_HOST" "mautic-db" && export MAUTIC_DB_HOST="mautic-db"
[ -z "${MAUTIC_DB_NAME:-}" ]     && upsert_env_var "MAUTIC_DB_NAME" "mautic"    && export MAUTIC_DB_NAME="mautic"
[ -z "${MAUTIC_DB_USER:-}" ]     && upsert_env_var "MAUTIC_DB_USER" "mautic"    && export MAUTIC_DB_USER="mautic"
[ -z "${MAUTIC_DB_PASSWORD:-}" ] && upsert_env_var "MAUTIC_DB_PASSWORD" "dev_mautic_db_pw" && export MAUTIC_DB_PASSWORD="dev_mautic_db_pw"
[ -z "${MAUTIC_DB_PORT:-}" ]     && upsert_env_var "MAUTIC_DB_PORT" "3306"      && export MAUTIC_DB_PORT="3306"
[ -z "${MAUTIC_ROOT_PW:-}" ]     && upsert_env_var "MAUTIC_ROOT_PW" "dev_mautic_root_pw"   && export MAUTIC_ROOT_PW="dev_mautic_root_pw"
# opzionale: dominio pubblico per HTTPS in Caddy e site_url Mautic
[ -z "${MAUTIC_DOMAIN:-}" ] && upsert_env_var "MAUTIC_DOMAIN" "" || true

# Mattermost: default + mapping admin unificato se mancano
[ -z "${MATTERMOST_SITEURL:-}" ]        && upsert_env_var "MATTERMOST_SITEURL" "http://chat.localhost" && export MATTERMOST_SITEURL="http://chat.localhost"

[ -z "${MATTERMOST_ADMIN_USER:-}" ]     && upsert_env_var "MATTERMOST_ADMIN_USER"  "$ADMIN_USER"  && export MATTERMOST_ADMIN_USER="$ADMIN_USER"
[ -z "${MATTERMOST_ADMIN_EMAIL:-}" ]    && upsert_env_var "MATTERMOST_ADMIN_EMAIL" "$ADMIN_EMAIL" && export MATTERMOST_ADMIN_EMAIL="$ADMIN_EMAIL"
[ -z "${MATTERMOST_ADMIN_PASS:-}" ]     && upsert_env_var "MATTERMOST_ADMIN_PASS"  "$ADMIN_PASS"  && export MATTERMOST_ADMIN_PASS="$ADMIN_PASS"

[ -z "${MATTERMOST_TEAM_NAME:-}" ]      && upsert_env_var "MATTERMOST_TEAM_NAME"   "cloudetta"    && export MATTERMOST_TEAM_NAME="cloudetta"
[ -z "${MATTERMOST_TEAM_DISPLAY:-}" ]   && upsert_env_var "MATTERMOST_TEAM_DISPLAY" "Cloudetta"    && export MATTERMOST_TEAM_DISPLAY="Cloudetta"

# === 2) Avvio (o riutilizzo) docker compose — con profili local/prod =========
# Se BOOTSTRAP_PROFILES non è definita, autodetect:
#  - "prod" se almeno un dominio pubblico è valorizzato
#  - altrimenti "local"
if [ -z "${BOOTSTRAP_PROFILES:-}" ]; then
  if [ -n "${DJANGO_DOMAIN}${ODOO_DOMAIN}${REDMINE_DOMAIN}${NEXTCLOUD_DOMAIN}${N8N_DOMAIN}${WIKI_DOMAIN}${MAUTIC_DOMAIN}${MATTERMOST_DOMAIN}" ]; then
    BOOTSTRAP_PROFILES="prod"
  else
    BOOTSTRAP_PROFILES="local"
  fi
fi

# Costruisci gli argomenti --profile
COMPOSE_PROFILES_ARGS=""
for p in ${BOOTSTRAP_PROFILES}; do
  COMPOSE_PROFILES_ARGS="$COMPOSE_PROFILES_ARGS --profile $p"
done

echo "[bootstrap] Profili scelti: ${BOOTSTRAP_PROFILES}"

# Evita che restino attivi entrambi i Caddy (uno per profilo)
if echo " ${BOOTSTRAP_PROFILES} " | grep -q " local "; then
  docker compose rm -sf caddy-prod 2>/dev/null || true
fi
if echo " ${BOOTSTRAP_PROFILES} " | grep -q " prod "; then
  docker compose rm -sf caddy-local 2>/dev/null || true
fi

# --- (micro-note) pre-pull immagini critiche per evitare errori di tag mancanti
echo "[bootstrap] Pull immagini Mautic…"
docker compose pull mautic mautic-cron || true

# Avvio/aggiorno lo stack (servizi senza profilo + profili selezionati)
echo "[bootstrap] Avvio/aggiorno docker compose… (profili: ${BOOTSTRAP_PROFILES})"
docker compose $COMPOSE_PROFILES_ARGS up -d --remove-orphans

# --- Avvio profili extra opzionali (es: "sso monitoring logging uptime") ---
if [ -n "${BOOTSTRAP_EXTRA_PROFILES:-}" ]; then
  EXTRA_ARGS=""
  for p in ${BOOTSTRAP_EXTRA_PROFILES}; do EXTRA_ARGS="$EXTRA_ARGS --profile $p"; done
  echo "[bootstrap] Avvio profili extra: ${BOOTSTRAP_EXTRA_PROFILES}"
  docker compose $EXTRA_ARGS up -d --remove-orphans
fi

# Rileva/aggiorna la rete internal del compose (serve a curl_net/wait_on_*)
CNET="$(detect_compose_net || true)"

# === 3) Attesa servizi (ordine corretto) =====================================
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
ODOO_URL="${ODOO_URL:-http://odoo:8069}"
N8N_URL="${N8N_URL:-http://n8n:5678}"
MAUTIC_URL="${MAUTIC_URL:-http://mautic:80}"
MATTERMOST_URL="${MATTERMOST_URL:-http://mattermost:8065}"

echo "[bootstrap] Attendo servizi…"
wait_on_http "$N8N_URL" 120 2 || true
wait_on_http "$NEXTCLOUD_URL" 120 2 || true

# Redmine DB -> init
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
# 4a) Django superuser (NO fallback: usa solo ENV)
echo "[bootstrap] Configuro Django superuser…"
docker compose exec -T django python - <<'PY' || true
import os, sys
os.environ.setdefault("DJANGO_SETTINGS_MODULE", os.environ.get("DJANGO_SETTINGS_MODULE","config.settings"))
required = ["DJANGO_ADMIN_USER","DJANGO_ADMIN_EMAIL","DJANGO_ADMIN_PASS"]
missing = [k for k in required if not os.environ.get(k)]
if missing:
    print("ERRORE Django: variabili mancanti:", ",".join(missing), file=sys.stderr)
    sys.exit(1)
try:
    import django; django.setup()
    from django.contrib.auth import get_user_model
    U = get_user_model()
    username = os.environ["DJANGO_ADMIN_USER"]
    email    = os.environ["DJANGO_ADMIN_EMAIL"]
    password = os.environ["DJANGO_ADMIN_PASS"]
    u, _ = U.objects.get_or_create(username=username, defaults={"email": email, "is_superuser": True, "is_staff": True})
    u.email = email
    u.set_password(password)
    u.save()
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
  [ -n "$d" ] || continue
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
: "${ADMIN_EMAIL:?metti ADMIN_EMAIL in .env}"
: "${ADMIN_PASS:?metti ADMIN_PASS in .env}"

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
  pass  = ENV[\"ADMIN_PASS\"]
  if email.to_s.strip.empty? || pass.to_s.strip.empty?
    abort(\"ENV mancanti: ADMIN_EMAIL/ADMIN_PASS\")
  end
  u = User.find_by_login(\"admin\")
  if u
    u.password = pass
    u.password_confirmation = pass
    u.mail = email
    u.must_change_passwd = false
    u.save!
    puts \"Redmine admin aggiornato: #{u.mail}\"
  else
    abort(\"ERRORE: utente admin non trovato\")
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

# --- 4e) Mautic (v6) — install CLI no-wizard + fix idempotenti ---
echo "[bootstrap] Configuro Mautic…"
wait_on_mysql mautic-db "${MAUTIC_ROOT_PW:-dev_mautic_root_pw}" 120 2 || true
# helper HTTP per Mautic: accettiamo 200/30x/401/403/404
mautic_http_ok() {
  local code
  code=$(docker run --rm --network "${CNET:-bridge}" \
          curlimages/curl -s -o /dev/null -w "%{http_code}" "$MAUTIC_URL" || true)
  echo "[check] $MAUTIC_URL → $code"
  echo "$code" | grep -qE '^(200|30[123]|401|403|404)$'
}

# Se hai un dominio, lo usiamo come site_url
MAUTIC_BASE_URL="${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN}}"
MAUTIC_URL="${MAUTIC_URL:-http://mautic:80}"

docker compose exec -T \
  -e MAUTIC_BASE_URL="${MAUTIC_BASE_URL}" \
  -e MAUTIC_DB_HOST="${MAUTIC_DB_HOST:-mautic-db}" \
  -e MAUTIC_DB_PORT="${MAUTIC_DB_PORT:-3306}" \
  -e MAUTIC_DB_DATABASE="${MAUTIC_DB_NAME:-mautic}" \
  -e MAUTIC_DB_USER="${MAUTIC_DB_USER:-mautic}" \
  -e MAUTIC_DB_PASSWORD="${MAUTIC_DB_PASSWORD:-dev_mautic_db_pw}" \
  -e MAUTIC_DB_SERVER_VERSION="mariadb-10.11" \
  -e MAUTIC_BOOTSTRAP_ADMIN_EMAIL="${ADMIN_EMAIL}" \
  -e MAUTIC_BOOTSTRAP_ADMIN_USER="${ADMIN_USER}" \
  -e MAUTIC_BOOTSTRAP_ADMIN_PASS="${ADMIN_PASS}" \
  mautic bash -lc '
set -e
cd /var/www/html
PHP=php

# Permessi minimi
chown -R www-data:www-data /var/www/html || true
find /var/www/html -type d -exec chmod 755 {} \; || true
find /var/www/html -type f -exec chmod 644 {} \; || true
[ -d var ] && chmod -R 775 var || true

CONFIG_FILE="config/local.php"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[mautic] Installazione CLI (no wizard)…"
  su -s /bin/sh -c "
    $PHP bin/console mautic:install \"${MAUTIC_BASE_URL:-http://mautic}\" \
      --db_driver=pdo_mysql \
      --db_host=\"${MAUTIC_DB_HOST}\" \
      --db_port=\"${MAUTIC_DB_PORT}\" \
      --db_name=\"${MAUTIC_DB_DATABASE}\" \
      --db_user=\"${MAUTIC_DB_USER}\" \
      --db_password=\"${MAUTIC_DB_PASSWORD}\" \
      --admin_username=\"${MAUTIC_BOOTSTRAP_ADMIN_USER}\" \
      --admin_email=\"${MAUTIC_BOOTSTRAP_ADMIN_EMAIL}\" \
      --admin_password=\"${MAUTIC_BOOTSTRAP_ADMIN_PASS}\" \
      --no-interaction
  " www-data
else
  echo "[mautic] Già installato: aggiorno schema…"
fi

# Migrazioni + plugin + cache
$PHP bin/console doctrine:migrations:migrate -n || true
$PHP bin/console mautic:plugins:reload -n || true

# Admin: aggiorna se esiste, altrimenti crea
if $PHP bin/console list 2>/dev/null | grep -q "mautic:user:update"; then
  $PHP bin/console mautic:user:update -u "${MAUTIC_BOOTSTRAP_ADMIN_USER}" \
    --password "${MAUTIC_BOOTSTRAP_ADMIN_PASS}" \
    --email "${MAUTIC_BOOTSTRAP_ADMIN_EMAIL}" 2>/dev/null || true
fi
if $PHP bin/console list 2>/dev/null | grep -q "mautic:user:create"; then
  $PHP bin/console mautic:user:create -u "${MAUTIC_BOOTSTRAP_ADMIN_USER}" \
    -p "${MAUTIC_BOOTSTRAP_ADMIN_PASS}" \
    -e "${MAUTIC_BOOTSTRAP_ADMIN_EMAIL}" --role="Administrator" 2>/dev/null || true
fi

# Site URL se disponibile
if [ -n "${MAUTIC_BASE_URL}" ]; then
  $PHP bin/console mautic:config:set --name=site_url --value="${MAUTIC_BASE_URL}" || true
fi

$PHP bin/console cache:clear -n || true
chown -R www-data:www-data /var/www/html || true
'

# Attendo HTTP “valido” (evita che la UI torni al wizard)
wait_on_http "$MAUTIC_URL" 120 2 || true


# prova HTTP e stampa log se serve
echo "[bootstrap] Attendo Mautic (prima risposta valida)…"
if ! mautic_http_ok; then
  echo "Mautic non ancora pronto. Controllo log:"
  docker compose exec -T mautic bash -lc '
    for f in var/log/*.log 2>/dev/null; do
      [ -f "$f" ] && { echo "==> $f"; tail -n 120 "$f"; }
    done || true
  ' || true
fi

# (opzionale) forza site_url se hai un dominio pubblico
if [ -n "${MAUTIC_DOMAIN}" ]; then
  echo "[bootstrap] Imposto Mautic site_url=https://${MAUTIC_DOMAIN}"
  docker compose exec -T mautic bash -lc '
    runuser -u www-data -- php bin/console \
      mautic:config:set --name=site_url --value="https://'"$MAUTIC_DOMAIN"'" || true
    runuser -u www-data -- php bin/console cache:clear -n || true
  '
fi



# 4f) Mattermost: admin, team, siteurl (idempotente, via mmctl --local)
echo "[bootstrap] Configuro Mattermost…"

# attendo l'HTTP pronto (ping)
wait_on_http "${MATTERMOST_URL%/}/api/v4/system/ping" 180 2 || true

# eseguo comandi in local-mode via socket (abilitato nel compose)
docker compose exec -T mattermost bash -lc '
set -e
export MMCTL_LOCAL_SOCKET_PATH="/var/tmp/mattermost_local.socket"

# wrapper comodo
mm() { mmctl --local "$@"; }

# 1) assicura SiteURL (oltre all env)
mm config set ServiceSettings.SiteURL "'"${MATTERMOST_SITEURL:-http://chat.localhost}"'" >/dev/null 2>&1 || true
mm config reload >/dev/null 2>&1 || true

# 2) crea/aggiorna utente admin
#   - se esiste, salta la creazione; se serve, reset pass/email si può fare con mmctl user update
if ! mm user list | awk '"'"'{print tolower($2)}'"'"' | grep -qx "$(echo "'"${MATTERMOST_ADMIN_EMAIL}"'" | tr '"'"'A-Z'"'"' '"'"'a-z'"'"')"; then
  echo " - creo utente admin ${MATTERMOST_ADMIN_EMAIL}…"
  mm user create \
    --email "'"${MATTERMOST_ADMIN_EMAIL}"'" \
    --username "'"${MATTERMOST_ADMIN_USER}"'" \
    --password "'"${MATTERMOST_ADMIN_PASS}"'" \
    --system_admin >/dev/null
else
  echo " - utente admin già presente"
  # opzionale: forza password/email (idempotente, non fallire se non cambia)
  mm user update --password "'"${MATTERMOST_ADMIN_PASS}"'" "$(mm user search "'"${MATTERMOST_ADMIN_EMAIL}"'" | awk '"'"'NR==1{print $1}'"'"')" >/dev/null 2>&1 || true
fi

# 3) crea team se manca
if ! mm team list | awk '"'"'{print $2}'"'"' | grep -qx "'"${MATTERMOST_TEAM_NAME}"'"; then
  echo " - creo team ${MATTERMOST_TEAM_NAME}…"
  mm team create \
    --name "'"${MATTERMOST_TEAM_NAME}"'" \
    --display_name "'"${MATTERMOST_TEAM_DISPLAY}"'" \
    --type open >/dev/null
else
  echo " - team già presente"
fi

# 4) aggiungi admin al team (idempotente)
mm team add "'"${MATTERMOST_TEAM_NAME}"'" "'"${MATTERMOST_ADMIN_EMAIL}"'" >/dev/null 2>&1 || true

# 5) reload config
mm config reload >/dev/null 2>&1 || true

echo " - Mattermost pronto."
' || echo "WARN: configurazione Mattermost non completata (verifica i log)."

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
# n8n basic auth: usa credenziali unificate, salvo override esplicito
N8N_USER="${N8N_USER:-$ADMIN_USER}"
N8N_PASS="${N8N_PASSWORD:-$ADMIN_PASS}"

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

echo "[bootstrap] Integrazioni n8n: base impostata."

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
- Mautic     → ${MAUTIC_URL}           | login: ${ADMIN_USER}/${ADMIN_PASS}
- n8n        → ${N8N_URL}              | BasicAuth: ${N8N_USER}/${N8N_PASS}
- DokuWiki   → http://wiki.localhost   | (consigliato BasicAuth in Caddy)
- Mattermost → ${MATTERMOST_URL}       | login: ${MATTERMOST_ADMIN_EMAIL}/${MATTERMOST_ADMIN_PASS} (team: ${MATTERMOST_TEAM_NAME})

Nextcloud:
- trusted_domains = ${TRUSTED_DOMAINS}
- overwrite.cli.url = ${PUBLIC_DOMAIN:-<non impostato>}

Redmine:
- API key (REDMINE_API_KEY in .env): ${REDMINE_API_KEY:-<non disponibile>}

Mautic (DB):
- host=${MAUTIC_DB_HOST} name=${MAUTIC_DB_NAME} user=${MAUTIC_DB_USER} port=${MAUTIC_DB_PORT}

Mail (.env):
- MAIL_PROVIDER=${MAIL_PROVIDER:-${MAIL_PROVIDER}}
- MAIL_USER=${MAIL_USER:-${MAIL_USER}}
- MAIL_PASS=******

Mattermost:
- SiteURL = ${MATTERMOST_SITEURL}
- Team = ${MATTERMOST_TEAM_NAME} (${MATTERMOST_TEAM_DISPLAY})

INFO
