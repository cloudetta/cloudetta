Hai beccato un classico: quei WARN li stampa **docker compose** perché dentro al campo `command:` vede variabili shell come `$LIST`, `$SEG_CMD`, `$state_dir` ecc. e prova a farci **variable-substitution di Compose**. Non trovandole nell’ambiente esterno, le sostituisce con stringa vuota e logga:

> `WARN The "LIST" variable is not set. Defaulting to a blank string.`

Risultato: lo script parte con variabili vuote → cron che non fanno nulla.

Hai due modi per fixare:

## Opzione 1 (robusta e pulita): script esterno montato nel container

Eviti ogni escape e lasci la shell fare il suo lavoro.

1. Crea `mautic/cron-runner.sh` nel repo con questo contenuto (è quello che avevamo messo in `command:` pari pari):

```bash
#!/bin/sh
set -e
cd /var/www/html

echo "[cron] wait for app + db…"
# attendo bin/console
for i in $(seq 1 120); do [ -f bin/console ] && break; sleep 2; done
# attendo DB TCP + auth
for i in $(seq 1 60); do
  mysqladmin ping -h "$MAUTIC_DB_HOST" -P "$MAUTIC_DB_PORT" -u"$MAUTIC_DB_USER" -p"$MAUTIC_DB_PASSWORD" >/dev/null 2>&1 && break
  sleep 2
done

# autodetect comandi
LIST="$(php bin/console list 2>/dev/null || true)"

SEG_CMD="mautic:segments:update"
echo "$LIST" | grep -q "mautic:segments:update" || SEG_CMD="mautic:segments:rebuild"

CAMP_UPDATE="mautic:campaigns:update"
echo "$LIST" | grep -q "mautic:campaigns:update" || CAMP_UPDATE="mautic:campaigns:rebuild"

CAMP_TRIGGER="mautic:campaigns:trigger"
MSG_SEND="mautic:messages:send"
MAIL_SEND="mautic:emails:send"

FETCH_CMD=""
echo "$LIST" | grep -q "mautic:emails:fetch" && FETCH_CMD="mautic:emails:fetch"

WEBHOOKS_CMD=""
echo "$LIST" | grep -q "mautic:webhooks:process" && WEBHOOKS_CMD="mautic:webhooks:process"

CLEANUP_CMD=""
echo "$LIST" | grep -q "mautic:maintenance:cleanup" && CLEANUP_CMD="mautic:maintenance:cleanup"

echo "[cron] using:"
echo "  $SEG_CMD | $CAMP_UPDATE | $CAMP_TRIGGER | $MSG_SEND | $MAIL_SEND | ${FETCH_CMD:-<no-fetch>} | ${WEBHOOKS_CMD:-<no-webhooks>} | ${CLEANUP_CMD:-<no-cleanup>}"

# scheduler
SEG_EVERY=900
CAMP_UPDATE_EVERY=900
TRIGGER_EVERY=300
MSG_SEND_EVERY=600
MAIL_SEND_EVERY=600
FETCH_EVERY=900
WEBHOOKS_EVERY=600

state_dir=/tmp/mautic-cron
mkdir -p "$state_dir"

now_s() { date +%s; }
due() { f="$1"; int="$2"; last=0; [ -f "$f" ] && last="$(cat "$f" 2>/dev/null || echo 0)"; [ $(( $(now_s) - last )) -ge "$int" ]; }
mark() { date +%s > "$1" 2>/dev/null || true; }

# cleanup 03:30 Europe/Rome
cleanup_due_today() {
  [ -z "$CLEANUP_CMD" ] && return 1
  stamp="$state_dir/cleanup.day"
  today="$(date +%F)"
  [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$today" ] && return 1
  hhmm="$(date +%H:%M)"
  [ "$hhmm" = "03:30" ]
}

echo "[cron] loop avviato…"
while true; do
  if due "$state_dir/segments.ts" "$SEG_EVERY"; then
    echo "[cron] $(date) $SEG_CMD"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$SEG_CMD" --batch-limit=500 -n || true
    mark "$state_dir/segments.ts"
  fi

  if due "$state_dir/campupd.ts" "$CAMP_UPDATE_EVERY"; then
    echo "[cron] $(date) $CAMP_UPDATE"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$CAMP_UPDATE" -n || true
    mark "$state_dir/campupd.ts"
  fi

  if due "$state_dir/camptrig.ts" "$TRIGGER_EVERY"; then
    echo "[cron] $(date) $CAMP_TRIGGER"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$CAMP_TRIGGER" -n || true
    mark "$state_dir/camptrig.ts"
  fi

  if due "$state_dir/msgsend.ts" "$MSG_SEND_EVERY"; then
    echo "[cron] $(date) $MSG_SEND"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$MSG_SEND" -n || true
    mark "$state_dir/msgsend.ts"
  fi

  if due "$state_dir/mailsend.ts" "$MAIL_SEND_EVERY"; then
    echo "[cron] $(date) $MAIL_SEND"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$MAIL_SEND" -n || true
    mark "$state_dir/mailsend.ts"
  fi

  if [ -n "$FETCH_CMD" ] && due "$state_dir/fetch.ts" "$FETCH_EVERY"; then
    echo "[cron] $(date) $FETCH_CMD"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$FETCH_CMD" -n || true
    mark "$state_dir/fetch.ts"
  fi

  if [ -n "$WEBHOOKS_CMD" ] && due "$state_dir/webhooks.ts" "$WEBHOOKS_EVERY"; then
    echo "[cron] $(date) $WEBHOOKS_CMD"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$WEBHOOKS_CMD" -n || true
    mark "$state_dir/webhooks.ts"
  fi

  if cleanup_due_today; then
    echo "[cron] $(date) $CLEANUP_CMD (daily)"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$CLEANUP_CMD" -n || true
    date +%F > "$state_dir/cleanup.day" 2>/dev/null || true
    runuser -u www-data -- php -d memory_limit=-1 bin/console cache:clear -n || true
  fi

  sleep 60
done
```

2. Rendi eseguibile:

```bash
chmod +x mautic/cron-runner.sh
```

3. Modifica **solo** il servizio `mautic-cron` in `docker-compose.yml` così:

```yaml
  mautic-cron:
    image: mautic/mautic:6-apache
    depends_on: [ mautic-db, mautic ]
    environment:
      MAUTIC_DB_HOST: mautic-db
      MAUTIC_DB_USER: mautic
      MAUTIC_DB_PASSWORD: ${MAUTIC_DB_PASSWORD}
      MAUTIC_DB_NAME: mautic
      MAUTIC_DB_PORT: "3306"
      MAUTIC_DB_SERVER_VERSION: "mariadb-10.11"
      PHP_INI_VALUE_DATE_TIMEZONE: Europe/Rome
      TZ: Europe/Rome
    volumes:
      - mautic_config:/var/www/html/config
      - mautic_media:/var/www/html/docroot/media
      - mautic_logs:/var/www/html/var/log
      - ./mautic/cron-runner.sh:/usr/local/bin/cron-runner.sh:ro
    networks: [ internal ]
    restart: unless-stopped
    entrypoint: ["/bin/sh","-lc","cron-runner.sh"]
```

Fatto questo, i WARN spariscono perché Compose non vede più `$VAR` nel `command:`.

## Opzione 2 (se vuoi tenere tutto inline nel compose)

Devi **escapare ogni `$` → `$$`** dentro a `command:` (anche in `$(...)`, `$SEG_CMD`, `$state_dir`, ecc.). È facile dimenticarne qualcuno e diventare un incubo da manutenere; per questo ti consiglio l’Opzione 1.

---

Dopo la modifica:

```bash
docker compose up -d mautic-cron
docker compose logs -f --no-log-prefix mautic-cron
```

Dovresti vedere il banner “`[cron] using: …`” con i comandi rilevati correttamente, e niente più WARN di Compose.
