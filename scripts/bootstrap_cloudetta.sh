#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Cloudetta Bootstrap Installer
# - Crea/aggiorna .env con credenziali base (mail incluse)
# - Avvia docker compose
# - Attende i servizi
# - Crea admin Django e Nextcloud (best-effort)
# - Genera automaticamente la API key di Redmine e la salva in .env
# - Lancia integration/setup_api_links.sh per collegare i workflow n8n
# Idempotente: puoi rilanciarlo in sicurezza.
# ============================================================================

# === 0) Parametri desiderati per l’ambiente (modifica se vuoi) ===============
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
else
  echo "[bootstrap] Trovato .env esistente: non lo sovrascrivo"
fi

# Esporta le variabili in ambiente corrente
set -a
. ./.env
# Sovrascrivi con le nostre scelte (se diverse)
N8N_PASSWORD="${N8N_PASSWORD:-$N8N_PASSWORD}"
MAIL_PROVIDER="$MAIL_PROVIDER"
MAIL_USER="$MAIL_USER"
MAIL_PASS="$MAIL_PASS"
set +a

# === 2) Avvia docker compose =================================================
echo "[bootstrap] Avvio docker compose…"
docker compose up -d

# === 3) Attendi che i servizi rispondano =====================================
DJANGO_URL="${DJANGO_URL:-http://django:8000}"
REDMINE_URL="${REDMINE_URL:-http://redmine:3000}"
NEXTCLOUD_URL="${NEXTCLOUD_URL:-http://nextcloud:80}"
N8N_URL="${N8N_URL:-http://n8n:5678}"

wait_on_http () {
  local url="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-2}"
  while [ "$tries" -gt 0 ]; do
    code=$(docker run --rm --network host curlimages/curl -s -o /dev/null -w "%{http_code}" "$url" || true)
    if echo "$code" | grep -qE '^(200|302|401|403)$'; then
      return 0
    fi
    tries=$((tries-1))
    sleep "$sleep_s"
  done
  echo "Timeout aspettando $url (ultimo codice: $code)"
  return 1
}

echo "[bootstrap] Attendo servizi…"
wait_on_http "$N8N_URL" 120 2 || true
wait_on_http "$NEXTCLOUD_URL" 120 2 || true
wait_on_http "$REDMINE_URL" 120 2 || true
wait_on_http "$DJANGO_URL" 120 2 || true

# === 4) Configurazioni applicative ===========================================

# 4a) Django: crea/aggiorna superuser
echo "[bootstrap] Configuro Django superuser…"
docker compose exec -T django python - <<PY || true
import os
os.environ.setdefault("DJANGO_SETTINGS_MODULE","config.settings")
try:
    import django; django.setup()
    from django.contrib.auth import get_user_model
    U = get_user_model()
    u, created = U.objects.get_or_create(username="${DJANGO_ADMIN_USER}", defaults={
        "email":"${DJANGO_ADMIN_EMAIL}",
        "is_superuser": True,
        "is_staff": True,
    })
    u.set_password("${DJANGO_ADMIN_PASS}")
    u.save()
    print("Django admin pronto:", u.username)
except Exception as e:
    print("WARN Django:", e)
PY

# 4b) Nextcloud: crea/aggiorna utente admin (best-effort)
echo "[bootstrap] Configuro Nextcloud admin…"
docker compose exec -T nextcloud bash -lc '
  if command -v occ >/dev/null 2>&1; then
    export OC_PASS="${NEXTCLOUD_ADMIN_PASS}"
    if ! occ user:list 2>/dev/null | grep -q " - '"${NEXTCLOUD_ADMIN_USER}"':"; then
      echo "Creo utente admin Nextcloud…"
      OC_PASS="${NEXTCLOUD_ADMIN_PASS}" occ user:add --password-from-env --display-name="Cloudetta Admin" '"${NEXTCLOUD_ADMIN_USER}"'
    else
      echo "Utente admin Nextcloud già presente, imposto password…"
      printf "%s\n" "'"${NEXTCLOUD_ADMIN_PASS}"'" | occ user:resetpassword --password-from-env '"${NEXTCLOUD_ADMIN_USER}"'
    fi
  else
    echo "occ non trovato, salto configurazione Nextcloud"
  fi
' || true

# 4c) Redmine: genera API key admin automaticamente e salvala in .env
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
  end
' 2>/dev/null || true)

REDMINE_API_KEY_GENERATED="$(echo "$REDMINE_KEY_OUTPUT" | sed -n 's/^API_KEY=//p' | tr -d '\r\n')"

if [ -n "${REDMINE_API_KEY_GENERATED}" ]; then
  echo "[bootstrap] API key Redmine ottenuta: ${REDMINE_API_KEY_GENERATED:0:6}********"
  # Scrivi/aggiorna REDMINE_API_KEY in .env
  if grep -q '^REDMINE_API_KEY=' .env; then
    sed -i.bak "s/^REDMINE_API_KEY=.*/REDMINE_API_KEY=${REDMINE_API_KEY_GENERATED}/" .env
  else
    printf "\nREDMINE_API_KEY=%s\n" "$REDMINE_API_KEY_GENERATED" >> .env
  fi
  export REDMINE_API_KEY="$REDMINE_API_KEY_GENERATED"
else
  echo "[bootstrap] ATTENZIONE: impossibile ottenere la API key di Redmine in automatico."
  echo "            Potrai inserirla manualmente in .env come REDMINE_API_KEY e rilanciare."
fi

# === 5) Esegui lo script di integrazione n8n con le variabili pronte =========
echo "[bootstrap] Eseguo integration/setup_api_links.sh…"
export DJANGO_USER="${DJANGO_ADMIN_USER}"
export DJANGO_PASS="${DJANGO_ADMIN_PASS}"
export NEXTCLOUD_USER="${NEXTCLOUD_ADMIN_USER}"
export NEXTCLOUD_PASS="${NEXTCLOUD_ADMIN_PASS}"
export N8N_USER="${N8N_USER}"
export N8N_PASS="${N8N_PASSWORD}"
# REDMINE_API_KEY è già esportata sopra se ottenuta

if [ -f "integration/setup_api_links.sh" ]; then
  bash integration/setup_api_links.sh
else
  echo "WARN: integration/setup_api_links.sh non trovato. Salto."
fi

echo "[bootstrap] Completato."
