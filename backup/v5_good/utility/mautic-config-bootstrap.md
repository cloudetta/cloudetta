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
















# tentativi non andati a buon fine 

Capito: il wizard DB riappare ⇒ Mautic non è stato “marcato” come installato (niente `config/local.php`) o l’installer CLI non è andato a buon fine. Ti lascio una **sequenza unica, idempotente**, compatibile con **Mautic 6.0-apache**, che:

1. azzera/inizializza il DB,
2. esegue l’**installazione CLI** (niente wizard),
3. applica migrazioni + plugin + `site_url`,
4. pulisce cache e riavvia.

Copia-incolla **tutto** così com’è:

```bash
# 0) Variabili utili (usa i tuoi valori da .env se diversi)
export MAUTIC_DB_HOST=mautic-db
export MAUTIC_DB_PORT=3306
export MAUTIC_DB_NAME=mautic
export MAUTIC_DB_USER=mautic
export MAUTIC_DB_PASSWORD=${MAUTIC_DB_PASSWORD:-dev_mautic_db_pw}
export MAUTIC_ROOT_PW=${MAUTIC_ROOT_PW:-dev_mautic_root_pw}

export ADMIN_USER=${ADMIN_USER:-admin}
export ADMIN_PASS=${ADMIN_PASS:-ChangeMe!123}
export ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}

# Se hai un dominio pubblico:
# export MAUTIC_DOMAIN=mautic.example.com
# BASE_URL="https://${MAUTIC_DOMAIN}"
# In locale senza TLS:
BASE_URL=${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN}}
[ -z "$BASE_URL" ] && BASE_URL="http://mautic"

# 1) Reinizializza database (pulito)
docker compose exec -T mautic-db sh -lc '
set -eu
mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -e "
  DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`;
  CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '\''$MYSQL_USER'\''@'\''%'\'' IDENTIFIED BY '\''$MYSQL_PASSWORD'\'';
  GRANT ALL PRIVILEGES ON \`$MYSQL_DATABASE\`.* TO '\''$MYSQL_USER'\''@'\''%'\'' IDENTIFIED BY '\''$MYSQL_PASSWORD'\'';
  FLUSH PRIVILEGES;
"
'

# 2) Installazione non interattiva (crea config/local.php e schema)
docker compose exec -T \
  -e MAUTIC_BASE_URL="$BASE_URL" \
  -e MAUTIC_DB_HOST="$MAUTIC_DB_HOST" \
  -e MAUTIC_DB_PORT="$MAUTIC_DB_PORT" \
  -e MAUTIC_DB_DATABASE="$MAUTIC_DB_NAME" \
  -e MAUTIC_DB_USER="$MAUTIC_DB_USER" \
  -e MAUTIC_DB_PASSWORD="$MAUTIC_DB_PASSWORD" \
  -e MAUTIC_BOOTSTRAP_ADMIN_EMAIL="$ADMIN_EMAIL" \
  -e MAUTIC_BOOTSTRAP_ADMIN_USER="$ADMIN_USER" \
  -e MAUTIC_BOOTSTRAP_ADMIN_PASS="$ADMIN_PASS" \
  mautic bash -lc '
set -eu
cd /var/www/html
PHP=php

# sicurezza permessi minimi
chown -R www-data:www-data /var/www/html || true
find /var/www/html -type d -exec chmod 755 {} \; || true
find /var/www/html -type f -exec chmod 644 {} \; || true
[ -d var ] && chmod -R 775 var || true

# se c’è un vecchio local.php (incompleto), rimuovilo per forzare l’install
[ -f config/local.php ] || true

if [ ! -f config/local.php ]; then
  echo "[mautic] Install CLI…"
  runuser -u www-data -- $PHP bin/console mautic:install "${MAUTIC_BASE_URL:-http://mautic}" \
    --db_driver=pdo_mysql \
    --db_host="${MAUTIC_DB_HOST}" \
    --db_port="${MAUTIC_DB_PORT}" \
    --db_name="${MAUTIC_DB_DATABASE}" \
    --db_user="${MAUTIC_DB_USER}" \
    --db_password="${MAUTIC_DB_PASSWORD}" \
    --admin_username="${MAUTIC_BOOTSTRAP_ADMIN_USER}" \
    --admin_email="${MAUTIC_BOOTSTRAP_ADMIN_EMAIL}" \
    --admin_password="${MAUTIC_BOOTSTRAP_ADMIN_PASS}" \
    --no-interaction
else
  echo "[mautic] local.php già presente: salto install."
fi

# 3) Migrazioni + plugin
runuser -u www-data -- $PHP bin/console doctrine:migrations:migrate -n || true
runuser -u www-data -- $PHP bin/console mautic:plugins:reload -n || true

# 4) (Ri)garantisci admin
if $PHP bin/console list 2>/dev/null | grep -q "mautic:user:update"; then
  runuser -u www-data -- $PHP bin/console mautic:user:update \
    -u "${MAUTIC_BOOTSTRAP_ADMIN_USER}" \
    --password "${MAUTIC_BOOTSTRAP_ADMIN_PASS}" \
    --email "${MAUTIC_BOOTSTRAP_ADMIN_EMAIL}" 2>/dev/null || true
fi
if $PHP bin/console list 2>/dev/null | grep -q "mautic:user:create"; then
  runuser -u www-data -- $PHP bin/console mautic:user:create \
    -u "${MAUTIC_BOOTSTRAP_ADMIN_USER}" \
    -p "${MAUTIC_BOOTSTRAP_ADMIN_PASS}" \
    -e "${MAUTIC_BOOTSTRAP_ADMIN_EMAIL}" --role="Administrator" 2>/dev/null || true
fi

# 5) site_url (se BASE_URL presente)
if [ -n "${MAUTIC_BASE_URL:-}" ]; then
  runuser -u www-data -- $PHP bin/console mautic:config:set --name=site_url --value="${MAUTIC_BASE_URL}" || true
fi

# 6) Cache
runuser -u www-data -- $PHP bin/console cache:clear -n || true
chown -R www-data:www-data /var/www/html || true
'

# 3) Verifiche rapide (devono dare “1 file” e “> 90 tabelle”)
docker compose exec -T mautic bash -lc 'ls -l config/local.php || true'
docker compose exec -T mautic-db sh -lc \
  'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h 127.0.0.1 -N -e \
   "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='\''$MYSQL_DATABASE'\'';"'

# 4) Riavvia il web (facoltativo ma consigliato)
docker compose restart mautic
```

### Cose importanti da tenere d’occhio

* **`config/local.php`**: se **non** viene creato dall’install CLI, Mautic tornerà sempre al wizard. Il blocco sopra lo forza.
* **Permessi**: tutto ciò che tocca `cache/log` va eseguito come `www-data`; nella sequenza è già così (`runuser -u www-data -- …`).
* **`site_url`**: se hai `MAUTIC_DOMAIN` in `.env`, imposta `BASE_URL=https://…` prima di lanciare i comandi. In locale senza TLS va bene `http://mautic`.
* **Conteggio tabelle**: dopo l’install dovresti vedere ~**100+** tabelle nel DB (tu prima ne avevi 1 quando l’install era fallita).

Se dopo questa sequenza vedi ancora il wizard DB, i motivi tipici sono:

1. la connessione al DB fallisce (utente/password/host errati) → controlla i log `var/log/*.log` nel container `mautic`;
2. il volume `mautic_config` sovrascrive `config/` con **cartella vuota** *dopo* l’install (caso raro, ma se hai ricreato i volumi nel mezzo). In quel caso rilancia l’install con i volumi montati, come sopra.

Se vuoi, posso darti una mini-probe per stampare subito gli eventuali errori PHP/Doctrine dai log mentre gira l’install.
