# BACKUP & RESTORE — Cloudetta

## 🇮🇹 Backup
- **Automazione**: container `backup` con cron h 02:00.
- **Contenuti**: dump DB (Postgres/MariaDB), tar.gz volumi, `docker save` immagini custom.
- **Manuale**: `docker exec -it backup /backup/backup.sh`.

### Ripristino (indicazioni)
- Postgres: `psql -U <user> -d <db> < dump.sql`
- MariaDB: `mysql -u <user> -p <db> < dump.sql`
- Volumi: estrai tar.gz nella directory del volume.
- Immagini: `docker load -i image.tar`.

## 🇬🇧 Backup
- **Automation**: `backup` container with 02:00 cron.
- **Includes**: DB dumps (Postgres/MariaDB), volume tar.gz, `docker save` for custom images.
- **Manual**: `docker exec -it backup /backup/backup.sh`.

### Restore (hints)
- Postgres: `psql -U <user> -d <db> < dump.sql`
- MariaDB: `mysql -u <user> -p <db> < dump.sql`
- Volumes: extract tar.gz into the named volume path.
- Images: `docker load -i image.tar`.
