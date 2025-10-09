#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Cloudetta Bootstrap Installer – locale + server con un solo pacchetto
# - Prepara/aggiorna .env (crea anche ADMIN_* unificati)
# - Genera/aggiorna automaticamente caddy/Caddyfile (locale+server)
# - Avvia/riutilizza docker compose
# - Attende servizi, configura: Nextcloud, Django, Redmine, Odoo, Mautic
# - Crea integrazioni n8n
# - Stampa riepilogo credenziali/URL
# Idempotente
# ============================================================================

# --------- helpers -----------------------------------------------------------
detect_compose_net(){ docker network ls --format '{{.Name}}' | grep -E '_internal$' | head -n1; }
CNET="$(detect_compose_net || true)"

curl_net(){ local url="$1"; shift; docker run --rm --network "${CNET:-bridge}" curlimages/curl -s "$@" "$url"; }

wait_on_http(){
  local url="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    code=$(docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    echo "[wait] $url → $code  (restano $tries tentativi)"
    if echo "$code" | grep -qE '^(200|30[123]|401|403|404)$'; then return 0; fi
    tries=$((tries-1)); sleep "$sleep_s"
  done
  echo "Timeout aspettando $url (ultimo codice: $code)"; return 1
}

wait_on_mysql(){
  local svc="$1"; local root_pw="$2"; local tries="${3:-60}"; local sleep_s="${4:-2}"
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T "$svc" mariadb -uroot -p"$root_pw" -e "SELECT 1" >/dev/null 2>&1; then
      echo "[wait] $svc → OK (MySQL pronto)"; return 0; fi
    echo "[wait] $svc → not ready (restano $tries)"; tries=$((tries-1)); sleep "$sleep_s"
  done; echo "Timeout aspettando MySQL su $svc"; return 1
}

wait_on_postgres(){
  local svc="$1"; local tries="${2:-60}"; local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T "$svc" bash -lc 'pg_isready -h 127.0.0.1 -U "${POSTGRES_USER:-postgres}"' >/dev/null 2>&1; then
      echo "[wait] $svc → OK (Postgres pronto)"; return 0; fi
    echo "[wait] $svc → not ready (restano $tries)"; tries=$((tries-1)); sleep "$sleep_s"
  done; echo "Timeout aspettando Postgres su $svc"; return 1
}

upsert_env_var(){
  local key="$1"; local val="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env && rm -f .env.bak || true
  else
    printf "\n%s=%s\n" "$key" "$val" >> .env
  fi
}

# --------- 1) .env base + credenziali unificate -----------------------------
if [ ! -f .env ]; then
  echo "[bootstrap] Creo .env da .env.example"
  cp -f .env.example .env || true
  tmpfile=$(mktemp)
  awk -v n8p="${N8N_PASSWORD:-ChangeMe!123}" \
      -v mpv="${MAIL_PROVIDER:-sendgrid}" \
      -v mu="${MAIL_USER:-admin@example.com}" \
      -v mp="${MAIL_PASS:-ChangeMe!Mail!123}" '
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

# Credenziali admin unificate
: "${DJANGO_ADMIN_USER:=admin}"
: "${DJANGO_ADMIN_EMAIL:=admin@example.com}"
: "${DJANGO_ADMIN_PASS:=ChangeMe!123}"

: "${ADMIN_USER:=$DJANGO_ADMIN_USER}"
: "${ADMIN_PASS:=$DJANGO_ADMIN_PASS}"
: "${ADMIN_EMAIL:=$DJANGO_ADMIN_EMAIL}"

upsert_env_var "ADMIN_USER"  "$ADMIN_USER"
upsert_env_var "ADMIN_PASS"  "$ADMIN_PASS"
upsert_env_var "ADMIN_EMAIL" "$ADMIN_EMAIL"

grep -q '^NEXTCLOUD_ADMIN_USER=' .env || upsert_env_var "NEXTCLOUD_ADMIN_USER" "$ADMIN_USER"
grep -q '^NEXTCLOUD_ADMIN_PASS=' .env || upsert_env_var "NEXTCLOUD_ADMIN_PASS" "$ADMIN_PASS"
grep -q '^N8N_PASSWORD=' .env || upsert_env_var "N8N_PASSWORD" "$ADMIN_PASS"

# Redmine secret
if ! grep -q '^REDMINE_SECRET_KEY_BASE=' .env 2>/dev/null || grep -q '^REDMINE_SECRET_KEY_BASE=$' .env 2>/dev/null; then
  echo "[bootstrap] Genero REDMINE_SECRET_KEY_BASE…"
  if command -v openssl >/dev/null 2>&1; then RSKB="$(openssl rand -hex 64)"; else
    RSKB="$(head -c 64 /dev/urandom | od -vAn -tx1 | tr -d ' \n')"; fi
  upsert_env_var "REDMINE_SECRET_KEY_BASE" "$RSKB"
fi

# Valori default per Nextcloud/Odoo/domains
grep -q '^TRUSTED_DOMAINS=' .env || upsert_env_var "TRUSTED_DOMAINS" "localhost,127.0.0.1,nextcloud,nextcloud.localhost"
grep -q '^ODOO_DB=' .env || upsert_env_var "ODOO_DB" "cloudetta"
grep -q '^ODOO_MASTER_PASSWORD=' .env || upsert_env_var "ODOO_MASTER_PASSWORD" "$ADMIN_PASS"
grep -q '^ODOO_DEMO=' .env || upsert_env_var "ODOO_DEMO" "true"
grep -q '^ODOO_LANG=' .env || upsert_env_var "ODOO_LANG" "it_IT"
grep -q '^CADDY_EMAIL=' .env || upsert_env_var "CADDY_EMAIL" "admin@example.com"

# Nuove variabili facoltative per Mautic (default sicuri)
grep -q '^MAUTIC_DOMAIN=' .env || upsert_env_var "MAUTIC_DOMAIN" ""
grep -q '^MAUTIC_DB_PASSWORD=' .env || upsert_env_var "MAUTIC_DB_PASSWORD" "dev_mautic_db_pw"
grep -q '^MAUTIC_ROOT_PW=' .env || upsert_env_var "MAUTIC_ROOT_PW" "dev_mautic_root_pw"

# Domini pubblici (facoltativi – se li metti abiliti https prod)
for v in DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN; do
  grep -q "^${v}=" .env || upsert_env_var "$v" ""
done

# Carica env
set -a; . ./.env; set +a

# --------- 1bis) Genera/aggiorna Caddyfile (locale + server se presenti) ----
mkdir -p caddy
echo "[bootstrap] Genero/aggiorno caddy/Caddyfile…"

{
cat <<'LOCAL'
{
  # in locale restiamo in HTTP per *.localhost
  auto_https off
}

# ---- blocchi LOCALHOST (sempre presenti) ----
http://django.localhost    { reverse_proxy django:8000 }
http://odoo.localhost      { reverse_proxy odoo:8069 }
http://redmine.localhost   { reverse_proxy redmine:3000 }
# wiki con eventuale basicauth unificata
http://wiki.localhost {
  # basicauth /* { {$ADMIN_USER} {$WIKI_BCRYPT_HASH} }  # scommenta se vuoi proteggere in locale
  reverse_proxy dokuwiki:80
}
http://nextcloud.localhost { reverse_proxy nextcloud:80 }
http://n8n.localhost       { reverse_proxy n8n:5678 }
http://mautic.localhost    { reverse_proxy mautic:80 }
LOCAL

# blocchi PRODUZIONE (https automatico) – solo se hai valorizzato i domini
[ -n "${DJANGO_DOMAIN:-}" ]    && echo "${DJANGO_DOMAIN} { reverse_proxy django:8000 }"
[ -n "${ODOO_DOMAIN:-}" ]      && echo "${ODOO_DOMAIN} { reverse_proxy odoo:8069 }"
[ -n "${REDMINE_DOMAIN:-}" ]   && echo "${REDMINE_DOMAIN} { reverse_proxy redmine:3000 }"
[ -n "${WIKI_DOMAIN:-}" ]      && echo "${WIKI_DOMAIN} { basicauth /* { {\$ADMIN_USER} {\$WIKI_BCRYPT_HASH} } reverse_proxy dokuwiki:80 }"
[ -n "${NEXTCLOUD_DOMAIN:-}" ] && echo "${NEXTCLOUD_DOMAIN} { reverse_proxy nextcloud:80 }"
[ -n "${N8N_DOMAIN:-}" ]       && echo "${N8N_DOMAIN} { reverse_proxy n8n:5678 }"
[ -n "${MAUTIC_DOMAIN:-}" ]    && echo "${MAUTIC_DOMAIN} { reverse_proxy mautic:80 }"
} > caddy/Caddyfile

# Se manca l'hash per il wiki e vuoi proteggerlo in prod, puoi generarlo così:
if [ -z "${WIKI_BCRYPT_HASH:-}" ]; then
  HASH="$(docker run --rm caddy caddy hash-password --plaintext "${ADMIN_PASS}" 2>/dev/null || true)"
  [ -n "$HASH" ] && upsert_env_var "WIKI_BCRYPT_HASH" "$HASH" && export WIKI_BCRYPT_HASH="$HASH"
fi

# --------- 2) Avvio stack (o riuso) + reload Caddy ---------------------------
if docker compose ps -q | grep -q .; then
  echo "[bootstrap] Stack già attivo."
else
  echo "[bootstrap] Avvio docker compose…"
  docker compose up -d
fi

# prova reload "morbido" del Caddyfile; se fallisce, restart solo caddy
if docker compose ps -q caddy >/dev/null 2>&1; then
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile || docker compose restart caddy
fi

# rete aggiornata
CNET="$(detect_compose_net || true)"

# --------- 3) Attese & init DB Redmine --------------------------------------
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
ODOO_URL="${ODOO_URL:-http://odoo:8069}"
N8N_URL="${N8N_URL:-http://n8n:5678}"
MAUTIC_URL="${MAUTIC_URL:-http://mautic:80}"

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
" || echo "WARN: inizializzazione Redmine DB fallita (continuo)."

echo "[bootstrap] Riavvio Redmine con SECRET da .env…"
docker compose up -d --force-recreate --no-deps redmine || true
wait_on_http "$REDMINE_URL" 180 2 || true

# --------- 4) Django migrate + superuser ------------------------------------
wait_on_postgres django-db 120 2 || true
for i in $(seq 1 10); do
  if docker compose exec -T django bash -lc 'python manage.py migrate --noinput'; then break; fi
  sleep 2
done

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
    u, _ = U.objects.get_or_create(username=username, defaults={"email": email, "is_superuser": True, "is_staff": True})
    u.set_password(password); u.email=email; u.save()
    print("Django admin pronto:", u.username)
except Exception as e:
    print("WARN Django:", e, file=sys.stderr)
PY

# --------- 5) Nextcloud install + trusted_domains ----------------------------
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
  echo "Nextcloud già installato: aggiorno admin e domini…"
  export OC_PASS="'"${NEXTCLOUD_ADMIN_PASS}"'"; runuser -u www-data -- $PHP occ user:resetpassword --password-from-env "'"${NEXTCLOUD_ADMIN_USER}"'" || true
fi

# trusted_domains: localhost + eventuale dominio pubblico
idx=0
for d in '"${TRUSTED_DOMAINS//,/ }"' '"${NEXTCLOUD_DOMAIN:-}"'; do
  [ -n "$d" ] || continue
  runuser -u www-data -- $PHP occ config:system:set trusted_domains $idx --value "$d"
  idx=$((idx+1))
done

# overwrite.cli.url se presente dominio pubblico
if [ -n "'"${NEXTCLOUD_DOMAIN:-}"'" ]; then
  runuser -u www-data -- $PHP occ config:system:set overwrite.cli.url --value "https://'"${NEXTCLOUD_DOMAIN}"'"
fi
' || echo "WARN: configurazione Nextcloud non riuscita (occ)."

# --------- 6) Odoo: master password + DB demo (idempotente) -----------------
echo "[bootstrap] Configuro Odoo (master password + DB demo)…"
docker compose exec -T odoo bash -lc '
set -e
install -m 600 /dev/stdin /var/lib/odoo/.odoorc <<EOF
[options]
admin_passwd = '"$ODOO_MASTER_PASSWORD"'
EOF
' || true
docker compose restart odoo >/dev/null 2>&1 || true
wait_on_http "${ODOO_URL%/}/web/login" 120 2 || true

# crea DB solo se manca
EXISTS=$(docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -X POST \
  -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
  "${ODOO_URL%/}/web/database/list" | tr -d '\r\n')
if ! echo "$EXISTS" | grep -q "\"${ODOO_DB}\""; then
  echo "[bootstrap] Creo Odoo DB '${ODOO_DB}' (demo=${ODOO_DEMO})…"
  docker run --rm --network "${CNET:-bridge}" curlimages/curl -s -X POST \
    "${ODOO_URL%/}/web/database/create" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "master_pwd=${ODOO_MASTER_PASSWORD}" \
    --data-urlencode "name=${ODOO_DB}" \
    --data-urlencode "lang=${ODOO_LANG:-en_US}" \
    --data-urlencode "login=${ADMIN_EMAIL}" \
    --data-urlencode "password=${ADMIN_PASS}" \
    --data-urlencode "demo=${ODOO_DEMO}" >/dev/null || true
fi

# --------- 6bis) Mautic: installazione/sync admin (idempotente) -------------
echo "[bootstrap] Configuro Mautic…"
wait_on_mysql mautic-db "${MAUTIC_ROOT_PW:-dev_mautic_root_pw}" 120 2 || true
wait_on_http "$MAUTIC_URL" 180 2 || true

docker compose exec -T mautic bash -lc '
set -e
PHP=php
cd /var/www/html

# prova a capire se è già installato: local.php esiste su Mautic <=4; su v5 la CLI risponde comunque
if [ ! -f app/config/local.php ] && [ ! -f config/local.php ]; then
  echo "Mautic non installato: tento installazione via CLI…"
  # Provo il comando di installazione non interattivo (se disponibile)
  if $PHP bin/console list | grep -q "mautic:install"; then
    $PHP bin/console mautic:install -n \
      --db_driver=pdo_mysql \
      --db_host="${MAUTIC_DB_HOST:-mautic-db}" \
      --db_name="${MAUTIC_DB_NAME:-mautic}" \
      --db_user="${MAUTIC_DB_USER:-mautic}" \
      --db_password="${MAUTIC_DB_PASSWORD:-dev_mautic_db_pw}" \
      --db_port="${MAUTIC_DB_PORT:-3306}" \
      --admin_username="${ADMIN_USER:-admin}" \
      --admin_password="${ADMIN_PASS:-ChangeMe!123}" \
      --admin_email="${ADMIN_EMAIL:-admin@example.com}" \
      --site_url="${MAUTIC_DOMAIN:+https://$MAUTIC_DOMAIN}"
  else
    echo "CLI install non disponibile; proseguirò con sync utente/admin dopo migrazioni."
  fi
fi

# Assicura migrazioni DB
if $PHP bin/console list | grep -q "doctrine:migrations:migrate"; then
  $PHP bin/console doctrine:migrations:migrate -n || true
fi

# Crea/aggiorna utente admin
if $PHP bin/console list | grep -q "mautic:user:create"; then
  # prova update, altrimenti crea
  $PHP bin/console mautic:user:update -u "${ADMIN_USER:-admin}" --password "${ADMIN_PASS:-ChangeMe!123}" --email "${ADMIN_EMAIL:-admin@example.com}" 2>/dev/null || \
  $PHP bin/console mautic:user:create -u "${ADMIN_USER:-admin}" -p "${ADMIN_PASS:-ChangeMe!123}" -e "${ADMIN_EMAIL:-admin@example.com}" --role="Administrator" || true
fi

# Configura site_url se MAUTIC_DOMAIN è presente
if [ -n "${MAUTIC_DOMAIN:-}" ] && $PHP bin/console list | grep -q "mautic:config:set"; then
  $PHP bin/console mautic:config:set --name="site_url" --value="https://${MAUTIC_DOMAIN}" || true
fi
' || echo "WARN: configurazione Mautic non completamente automatizzabile (verifica via UI)."

# --------- 7) Redmine: sync admin + API key ---------------------------------
echo "[bootstrap] Imposto password/email admin Redmine…"
docker compose exec -T redmine bash -lc '
bundle exec rails runner "
  u = User.find_by_login(\"admin\")
  if u
    u.password = ENV[\"ADMIN_PASS\"]; u.password_confirmation = ENV[\"ADMIN_PASS\"]
    u.mail = (ENV[\"ADMIN_EMAIL\"].to_s.empty? ? \"admin@example.com\" : ENV[\"ADMIN_EMAIL\"])
    u.must_change_passwd = false; u.save!
    puts \"Redmine admin aggiornato: #{u.mail}\"
  else
    puts \"ERRORE: utente admin non trovato\"
  end
"
' || true

echo "[bootstrap] Genero API key Redmine…"
REDMINE_KEY_OUTPUT=$(docker compose exec -T redmine bash -lc '
  bundle exec rails runner "
    u = User.find_by_login(\"admin\") || User.find(1)
    if u.nil?
      puts \"ERR: admin non trovato\"
    else
      if u.api_key.nil?
        t = Token.create(user: u, action: \"api\"); puts \"API_KEY=#{t.value}\"
      else
        puts \"API_KEY=#{u.api_key}\"
      end
    end
  "
' 2>/dev/null || true)
REDMINE_API_KEY_GENERATED="$(echo "$REDMINE_KEY_OUTPUT" | sed -n 's/^API_KEY=//p' | tr -d '\r\n')"
if [ -n "${REDMINE_API_KEY_GENERATED}" ]; then
  echo "[bootstrap] API key Redmine ottenuta: ${REDMINE_API_KEY_GENERATED:0:6}********"
  upsert_env_var "REDMINE_API_KEY" "$REDMINE_API_KEY_GENERATED"
  export REDMINE_API_KEY="$REDMINE_API_KEY_GENERATED"
else
  echo "[bootstrap] ATTENZIONE: impossibile ottenere la API key di Redmine in automatico."
fi

# --------- 8) n8n integrazioni base -----------------------------------------
echo "[bootstrap] Configuro integrazioni n8n…"
wait_on_http "$N8N_URL" 60 2 || true
create_n8n_workflow(){ local name="$1"; local payload="$2"; echo "Creazione workflow n8n: $name"; curl_net "$N8N_URL/workflows" -X POST -u "$ADMIN_USER:$N8N_PASSWORD" -H "Content-Type: application/json" -d "$payload" >/dev/null || true; }
curl_net "$N8N_URL/webhook" -X POST -u "$ADMIN_USER:$N8N_PASSWORD" -H "Content-Type: application/json" -d '{"name":"Django_New_Order","method":"POST","path":"/webhook/django-new-order"}' >/dev/null || true
read -r -d '' WF1 <<JSON
{"name":"Django_to_Redmine","nodes":[{"type":"HTTP Request","parameters":{"url":"${DJANGO_URL}/api/orders","responseFormat":"json"}},{"type":"HTTP Request","parameters":{"url":"${REDMINE_URL}/issues.json","options":{"headers":{"X-Redmine-API-Key":"${REDMINE_API_KEY:-}"}}}}]}
JSON
create_n8n_workflow "Django_to_Redmine" "$WF1"
read -r -d '' WF2 <<JSON
{"name":"Django_to_Nextcloud","nodes":[{"type":"HTTP Request","parameters":{"url":"${DJANGO_URL}/api/invoices","responseFormat":"json"}},{"type":"HTTP Request","parameters":{"url":"${NEXTCLOUD_URL}/remote.php/dav/files/${NEXTCLOUD_ADMIN_USER}/Fatture/","authentication":"predefinedCredentialType","sendBinaryData":true}}]}
JSON
create_n8n_workflow "Django_to_Nextcloud" "$WF2"
read -r -d '' WF3 <<JSON
{"name":"Odoo_to_Django","nodes":[{"type":"HTTP Request","parameters":{"url":"${ODOO_URL}","responseFormat":"json"}},{"type":"HTTP Request","parameters":{"url":"${DJANGO_URL}/api/sync/customers","responseFormat":"json"}}]}
JSON
create_n8n_workflow "Odoo_to_Django" "$WF3"

# --------- 9) Riepilogo ------------------------------------------------------
cat <<INFO

[bootstrap] Completato.

Credenziali amministratore (unificate):
- USER:   ${ADMIN_USER}
- PASS:   ${ADMIN_PASS}
- EMAIL:  ${ADMIN_EMAIL}

Accessi locali (sviluppo):
- Django     → http://django.localhost
- Odoo       → http://odoo.localhost
- Redmine    → http://redmine.localhost
- Nextcloud  → http://nextcloud.localhost
- n8n        → http://n8n.localhost
- DokuWiki   → http://wiki.localhost
- Mautic     → http://mautic.localhost

Accessi pubblici (se configurati in .env):
- DJANGO_DOMAIN=${DJANGO_DOMAIN:-<non impostato>}
- ODOO_DOMAIN=${ODOO_DOMAIN:-<non impostato>}
- REDMINE_DOMAIN=${REDMINE_DOMAIN:-<non impostato>}
- NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN:-<non impostato>}
- N8N_DOMAIN=${N8N_DOMAIN:-<non impostato>}
- WIKI_DOMAIN=${WIKI_DOMAIN:-<non impostato>}
- MAUTIC_DOMAIN=${MAUTIC_DOMAIN:-<non impostato>}

Nextcloud:
- trusted_domains = ${TRUSTED_DOMAINS} ${NEXTCLOUD_DOMAIN:+, $NEXTCLOUD_DOMAIN}

Redmine:
- API key salvata in .env → REDMINE_API_KEY=${REDMINE_API_KEY:-<n.d.>}

Mautic:
- DB: mautic@mautic-db (pw=${MAUTIC_DB_PASSWORD:-dev_mautic_db_pw})
- Admin: ${ADMIN_USER} / ${ADMIN_PASS}  (${ADMIN_EMAIL})

INFO
