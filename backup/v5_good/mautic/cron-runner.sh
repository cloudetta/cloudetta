#!/bin/sh
set -e
cd /var/www/html

echo "[cron] wait for app + db…"
# attendo bin/console
for i in $(seq 1 120); do
  [ -f bin/console ] && break; sleep 2
done
# attendo DB TCP + auth
for i in $(seq 1 60); do
  mysqladmin ping -h "$MAUTIC_DB_HOST" -P "$MAUTIC_DB_PORT" -u"$MAUTIC_DB_USER" -p"$MAUTIC_DB_PASSWORD" >/dev/null 2>&1 && break
  sleep 2
done

state_dir="/var/www/html/var/cron-state"
mkdir -p "$state_dir"

LIST="$(php bin/console list 2>/dev/null || true)"

SEG_CMD="${MAUTIC_SEG_CMD:-mautic:segments:update}"
echo "$LIST" | grep -q "mautic:segments:update" || SEG_CMD="mautic:segments:rebuild"

CAMP_UPDATE="${MAUTIC_CAMP_UPDATE_CMD:-mautic:campaigns:update}"
echo "$LIST" | grep -q "mautic:campaigns:update" || CAMP_UPDATE="mautic:campaigns:rebuild"

CAMP_TRIGGER="${MAUTIC_TRIGGER_CMD:-mautic:campaigns:trigger}"

MSG_SEND="${MAUTIC_MSG_SEND_CMD:-mautic:messages:send}"
echo "$LIST" | grep -q "mautic:messages:send" || MSG_SEND="mautic:emails:send"

MAIL_SEND="${MAUTIC_MAIL_SEND_CMD:-mautic:emails:send}"

# emails:fetch/email:fetch
if echo "$LIST" | grep -q "mautic:emails:fetch"; then
  FETCH_CMD="${MAUTIC_FETCH_CMD:-mautic:emails:fetch}"
elif echo "$LIST" | grep -q "mautic:email:fetch"; then
  FETCH_CMD="${MAUTIC_FETCH_CMD:-mautic:email:fetch}"
else
  FETCH_CMD=""
fi

# webhooks:process/webhook:process
if echo "$LIST" | grep -q "mautic:webhooks:process"; then
  WEBHOOKS_CMD="${MAUTIC_WEBHOOKS_CMD:-mautic:webhooks:process}"
elif echo "$LIST" | grep -q "mautic:webhook:process"; then
  WEBHOOKS_CMD="${MAUTIC_WEBHOOKS_CMD:-mautic:webhook:process}"
else
  WEBHOOKS_CMD=""
fi

# cleanup
if echo "$LIST" | grep -q "mautic:maintenance:cleanup"; then
  CLEANUP_CMD="${MAUTIC_CLEANUP_CMD:-mautic:maintenance:cleanup}"
else
  CLEANUP_CMD=""
fi

echo "[cron] using:"
echo "  $SEG_CMD | $CAMP_UPDATE | $CAMP_TRIGGER | $MSG_SEND | $MAIL_SEND | ${FETCH_CMD:-<no-fetch>} | ${WEBHOOKS_CMD:-<no-webhooks>} | ${CLEANUP_CMD:-<no-cleanup>}"

to_seconds() {
  v="$1"
  case "$v" in
    *s) echo $(( ${v%s} ));;
    *m) echo $(( ${v%m} * 60 ));;
    *h) echo $(( ${v%h} * 3600 ));;
    *)  echo "$v";;
  esac
}

SEG_EVERY="${SEG_EVERY:-5m}"
CAMP_UPDATE_EVERY="${CAMP_UPDATE_EVERY:-5m}"
TRIGGER_EVERY="${TRIGGER_EVERY:-5m}"
MSG_SEND_EVERY="${MSG_SEND_EVERY:-5m}"
MAIL_SEND_EVERY="${MAIL_SEND_EVERY:-5m}"
FETCH_EVERY="${FETCH_EVERY:-10m}"
WEBHOOKS_EVERY="${WEBHOOKS_EVERY:-2m}"
CLEANUP_AT="${CLEANUP_AT:-03:30}"

seg_int="$(to_seconds "$SEG_EVERY")"
cup_int="$(to_seconds "$CAMP_UPDATE_EVERY")"
trg_int="$(to_seconds "$TRIGGER_EVERY")"
msg_int="$(to_seconds "$MSG_SEND_EVERY")"
mail_int="$(to_seconds "$MAIL_SEND_EVERY")"
fch_int="$(to_seconds "$FETCH_EVERY")"
whk_int="$(to_seconds "$WEBHOOKS_EVERY")"

stamp() { date +%s > "$state_dir/$1.last"; }
last()  { [ -f "$state_dir/$1.last" ] && cat "$state_dir/$1.last" || echo 0; }
due()   { now=$(date +%s); last_t=$(last "$1"); int_s="$2"; [ $((now-last_t)) -ge "$int_s" ]; }

echo "[cron] loop avviato…"
while true; do
  if [ -n "$SEG_CMD" ] && due seg "$seg_int"; then
    echo "[cron] $(date) $SEG_CMD"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$SEG_CMD" --batch-limit=500 -n || true
    stamp seg
  fi

  if due campupd "$cup_int"; then
    echo "[cron] $(date) $CAMP_UPDATE"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$CAMP_UPDATE" -n || true
    stamp campupd
  fi

  if due trigger "$trg_int"; then
    echo "[cron] $(date) $CAMP_TRIGGER"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$CAMP_TRIGGER" -n || true
    stamp trigger
  fi

  if due msgsend "$msg_int"; then
    echo "[cron] $(date) $MSG_SEND"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$MSG_SEND" -n || true
    stamp msgsend
  fi

  if due mailsend "$mail_int"; then
    echo "[cron] $(date) $MAIL_SEND"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$MAIL_SEND" -n || true
    stamp mailsend
  fi

  if [ -n "$FETCH_CMD" ] && due fetch "$fch_int"; then
    echo "[cron] $(date) $FETCH_CMD"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$FETCH_CMD" -n || true
    stamp fetch
  fi

  if [ -n "$WEBHOOKS_CMD" ] && due webhooks "$whk_int"; then
    echo "[cron] $(date) $WEBHOOKS_CMD"
    runuser -u www-data -- php -d memory_limit=-1 bin/console "$WEBHOOKS_CMD" -n || true
    stamp webhooks
  fi

  if [ -n "$CLEANUP_CMD" ]; then
    today="$(date +%F)"
    hhmm="$(date +%H:%M)"
    if [ "$hhmm" = "$CLEANUP_AT" ] && [ ! -f "$state_dir/cleanup.$today" ]; then
      echo "[cron] $(date) $CLEANUP_CMD (daily)"
      runuser -u www-data -- php -d memory_limit=-1 bin/console "$CLEANUP_CMD" -n || true
      : > "$state_dir/cleanup.$today"
    fi
  fi

  sleep 30
done
