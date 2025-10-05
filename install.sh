#!/usr/bin/env bash
set -e

echo "[*] Creating data directories..."
mkdir -p caddy odoo-addons django django/static django/media backups integration backup
mkdir -p data/{django-db-data,odoo-data,postgres-odoo-data,redis-data,redmine-data,redmine-db-data,nextcloud-data,nextcloud-db-data,n8n-data,dokuwiki-data}

if [ ! -f ".env" ]; then
  echo "[*] Generating .env from .env.example (remember to edit secrets)"
  cp .env.example .env
fi

echo "[*] Building images..."
docker compose build

echo "[*] Starting stack..."
docker compose up -d

echo "[*] Running Django migrations + superuser (admin/admin)"
docker exec -it django python manage.py migrate
echo "from django.contrib.auth import get_user_model; User=get_user_model(); User.objects.filter(username='admin').exists() or User.objects.create_superuser('admin','admin@example.com','admin')" | docker exec -i django python manage.py shell

echo "[*] Collecting static..."
docker exec -it django python manage.py collectstatic --noinput

echo "[*] Demo setup placeholders:"
echo " - Odoo demo script: odoo-addons/demo_setup.py (adjust and run inside container if needed)"
echo " - n8n workflows: run ./integration/setup_api_links.sh after services are healthy"

echo "[*] Done. Visit:"
echo "  Django:     https://django.example.com or http://django.localhost"
echo "  Odoo:       https://odoo.example.com or http://odoo.localhost"
echo "  Nextcloud:  https://nextcloud.example.com or http://nextcloud.localhost"
echo "  Redmine:    https://redmine.example.com or http://redmine.localhost"
echo "  DokuWiki:   https://wiki.example.com or http://wiki.localhost"
echo "  n8n:        https://n8n.example.com or http://n8n.localhost"
