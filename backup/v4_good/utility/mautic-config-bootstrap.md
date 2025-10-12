Sì, con Mautic puoi fare un **bootstrap 100% automatizzato e production-ready**: config DB + creazione admin in modo non-interattivo al primo avvio del container.

Qui sotto trovi un esempio **Docker Compose** + **init script idempotente** che:

* prepara MariaDB,
* avvia Mautic,
* **se non è ancora installato** esegue `php bin/console mautic:install …` passando *tutti* i parametri (DB e Admin),
* poi parte normalmente in modalità web.

> Riferimenti ufficiali: la CLI `mautic:install` supporta opzioni per DB e admin (username/email/password, ecc.) e l’immagine Docker espone le env `MAUTIC_DB_*`. ([docs.mautic.org][1])

---

### `docker-compose.yml`

```yaml
services:
  db:
    image: mariadb:11
    environment:
      MYSQL_DATABASE: mautic
      MYSQL_USER: mautic
      MYSQL_PASSWORD: supersegretodb
      MYSQL_ROOT_PASSWORD: rootpass
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p$$MYSQL_ROOT_PASSWORD"]
      interval: 5s
      timeout: 3s
      retries: 20

  mautic:
    image: mautic/mautic:5-apache
    depends_on:
      db:
        condition: service_healthy
    environment:
      # DB per entrypoint e per install CLI
      MAUTIC_DB_HOST: db
      MAUTIC_DB_PORT: "3306"
      MAUTIC_DB_DATABASE: mautic
      MAUTIC_DB_USER: mautic
      MAUTIC_DB_PASSWORD: supersegretodb
      # Ruolo container (web). Per cron/worker vedi note sotto.
      DOCKER_MAUTIC_ROLE: mautic_web
      # opzionale: timezone PHP
      PHP_INI_VALUE_DATE_TIMEZONE: Europe/Rome
      # Parametri admin per bootstrap (usati dallo script)
      MAUTIC_BOOTSTRAP_ADMIN_EMAIL: admin@example.com
      MAUTIC_BOOTSTRAP_ADMIN_USER: admin
      MAUTIC_BOOTSTRAP_ADMIN_PASS: "CambiaSubito!123"
      MAUTIC_BASE_URL: "https://mautic.example.com"
    volumes:
      - mautic_config:/var/www/html/config
      - mautic_media:/var/www/html/docroot/media
      - mautic_logs:/var/www/html/var/logs
      - ./init-mautic.sh:/docker-entrypoint-wait/init-mautic.sh:ro
    entrypoint: ["/bin/sh","-c"]
    command: |
      '
      # avvia Apache+Mautic in background (entrypoint ufficiale)
      /usr/local/bin/docker-entrypoint.sh apache2-foreground &

      # attende che la webapp sia pronta a eseguire la CLI e che il DB risponda
      echo "Waiting for Mautic files and DB..."
      for i in $(seq 1 120); do
        [ -f /var/www/html/bin/console ] && mysqladmin ping -h "$MAUTIC_DB_HOST" -P "$MAUTIC_DB_PORT" -u"$MAUTIC_DB_USER" -p"$MAUTIC_DB_PASSWORD" >/dev/null 2>&1 && break
        sleep 2
      done

      # bootstrap idempotente (installa solo se manca local.php)
      /bin/sh /docker-entrypoint-wait/init-mautic.sh || true

      # foreground per tenere vivo il container
      wait -n
      '

volumes:
  db_data:
  mautic_config:
  mautic_media:
  mautic_logs:
```

### `init-mautic.sh`

```sh
#!/bin/sh
set -e

cd /var/www/html

CONFIG_FILE="config/local.php"
if [ -f "$CONFIG_FILE" ]; then
  echo "Mautic risulta già installato ($CONFIG_FILE presente). Skip bootstrap."
  exit 0
fi

# Legge variabili
BASE_URL="${MAUTIC_BASE_URL:?MAUTIC_BASE_URL mancante}"
DB_HOST="${MAUTIC_DB_HOST:?}"
DB_PORT="${MAUTIC_DB_PORT:-3306}"
DB_NAME="${MAUTIC_DB_DATABASE:?}"
DB_USER="${MAUTIC_DB_USER:?}"
DB_PASS="${MAUTIC_DB_PASSWORD:?}"

ADMIN_EMAIL="${MAUTIC_BOOTSTRAP_ADMIN_EMAIL:?}"
ADMIN_USER="${MAUTIC_BOOTSTRAP_ADMIN_USER:-admin}"
ADMIN_PASS="${MAUTIC_BOOTSTRAP_ADMIN_PASS:?}"

# Esegue install non-interattiva (opzioni ufficiali)
# NB: eseguire come www-data per permessi corretti
su -s /bin/sh -c "
  php ./bin/console mautic:install \"$BASE_URL\" \
    --db_driver=pdo_mysql \
    --db_host=\"$DB_HOST\" \
    --db_port=\"$DB_PORT\" \
    --db_name=\"$DB_NAME\" \
    --db_user=\"$DB_USER\" \
    --db_password=\"$DB_PASS\" \
    --admin_username=\"$ADMIN_USER\" \
    --admin_email=\"$ADMIN_EMAIL\" \
    --admin_password=\"$ADMIN_PASS\"
" www-data

echo "Installazione completata. Admin: $ADMIN_USER <$ADMIN_EMAIL>"
```

**Come funziona**

* Al primo run non esiste `config/local.php`: lo script lancia `mautic:install` con DB e credenziali admin; al termine Mautic è pronto al login. Opzioni e sintassi sono quelle documentate (DB + campi admin). ([docs.mautic.org][1])
* Le env `MAUTIC_DB_*` sono supportate dall’immagine ufficiale e utili anche all’entrypoint; se preferisci **Docker secrets**, c’è anche `MAUTIC_DB_PASSWORD_FILE`. ([GitHub][2])
* L’esecuzione CLI dal container è il flusso raccomandato nelle note del repo Docker (vedi esempio `php ./bin/console mautic:install …`). ([GitHub][2])

**Production tips**

* Usa **TLS** e metti `MAUTIC_BASE_URL` al tuo hostname pubblico (es. dietro Traefik/Caddy/Nginx).
* Tieni separati i ruoli:

  * `mautic_web` (come sopra),
  * un container `mautic_cron` per i cron (stessa immagine, `DOCKER_MAUTIC_ROLE=mautic_cron`),
  * opzionale `mautic_worker` per le code (messenger). ([GitHub][2])
* Persisti i volumi `config/`, `docroot/media/`, `var/logs/`. ([GitHub][2])
* Imposta password forti e, se possibile, **secrets** per il DB. ([Mautic Forums][3])

Vuoi che adatti il compose con Traefik e i cron già pronti (Italia/Europe/Rome) partendo dal tuo dominio?

[1]: https://docs.mautic.org/en/4.x/getting_started/how_to_install_mautic.html "Installation — Mautic Documentation 0.1 documentation"
[2]: https://github.com/mautic/docker-mautic "GitHub - mautic/docker-mautic: Docker Image for Mautic"
[3]: https://forum.mautic.org/t/feedback-on-the-mautic-5-docker-image-experience/34591?utm_source=chatgpt.com "Feedback on the Mautic 5 docker image experience"
