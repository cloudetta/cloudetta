#!/usr/bin/env bash
set -e

STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=/backups/${STAMP}
mkdir -p "$BACKUP_DIR"

echo "[*] Backup avviato in $BACKUP_DIR"

# 1) DB dumps
echo "[*] Dump Postgres (Django)..."
docker exec django-db pg_dump -U django -d django > "$BACKUP_DIR/django_db.sql"

echo "[*] Dump Postgres (Odoo)..."
docker exec odoo-db pg_dumpall -U odoo > "$BACKUP_DIR/odoo_db.sql"

echo "[*] Dump MariaDB (Redmine)..."
docker exec redmine-db sh -c 'exec mysqldump -u redmine -p"$MYSQL_PASSWORD" redmine' > "$BACKUP_DIR/redmine_db.sql"

echo "[*] Dump MariaDB (Nextcloud)..."
docker exec nextcloud-db sh -c 'exec mysqldump -u nextcloud -p"$MYSQL_PASSWORD" nextcloud' > "$BACKUP_DIR/nextcloud_db.sql"

# 2) Volumi principali (compressi)
for V in odoo-data redis-data redmine-data redmine-db-data nextcloud-data nextcloud-db-data dokuwiki-data n8n-data django-db-data; do
  echo "[*] Archiviazione volume: $V"
  tar -czf "$BACKUP_DIR/${V}.tar.gz" -C "/$V" . || echo "(!) Warning: volume $V not mounted in backup container"
done

# 3) Immagini Docker custom (se esistono)
echo "[*] Salvataggio immagini Docker custom..."
if docker image inspect django:latest >/dev/null 2>&1; then
  docker save django:latest -o "$BACKUP_DIR/django-image.tar" || true
fi
if docker image inspect odoo:latest >/dev/null 2>&1; then
  docker save odoo:latest -o "$BACKUP_DIR/odoo-image.tar" || true
fi

echo "[*] Backup completato: $BACKUP_DIR"
