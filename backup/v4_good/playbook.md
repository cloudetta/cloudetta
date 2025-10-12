perfetto — ecco un **playbook di upgrade** pronto all’uso per il tuo stack con profili `local`/`prod`, versioni pinnate e backup centralizzato. È pensato per aggiornare **una o più immagini alla volta** (es. Nextcloud 32.x→32.y, MariaDB 10.11.x→10.11.y, Redmine 6.1.x, n8n 1.101.x, Mattermost 10.7.x, ecc.) in modo sicuro, con rollback rapido.

---

# Playbook di upgrade (local/prod)

## 0) Prerequisiti e regole d’oro

* **Mai** aggiornare “tutto insieme”. Procedi **per servizio**.
* **Backup verificato** prima di ogni step (e prova un *restore secco* su dev se il salto è maggiore di patch).
* **Leggi le release notes** dei servizi con schema/DB (Nextcloud, Redmine, Mautic, Mattermost, Odoo) per eventuali **step manuali**.
* **Blocca gli ingressi** (maintenance mode o finestra di manutenzione) per evitare scritture durante migrazioni.

---

## 1) Preparazione (comune)

### 1.1 Staging (facoltativo ma consigliato)

* Clona l’ambiente su una VM/stage, copia `.env` e **volumi** (solo per servizi che aggiorni).
* Aggiorna le tag nell’`docker-compose.yml` di stage, prova il flusso completo.

### 1.2 Raccogli Info

```bash
# quali servizi sono up e versioni correnti
docker compose ps
docker compose images
# spazio libero (serve per dump)
df -h
```

---

## 2) Backup coerente (prima di ogni upgrade)

> Usa il container `backup` già presente. In alternativa fai dump mirati come sotto.

### 2.1 Dump mirati per il servizio oggetto di upgrade

**PostgreSQL (django-db / odoo-db / mattermost-db)**

```bash
# Esempio: django-db
docker compose exec -T django-db pg_dump -U django -F c -d django > backups/django_$(date +%F_%H%M).dump

# Odoo DB (utente: odoo, db: postgres in questo setup; se DB per odoo è “cloudetta”, dump quello)
docker compose exec -T odoo-db pg_dump -U odoo -F c -d postgres > backups/odoo_pg_$(date +%F_%H%M).dump
# Se Odoo usa un DB dedicato, sostituisci -d cloudetta
```

**MariaDB/MySQL (redmine-db / nextcloud-db / mautic-db)**

```bash
# Redmine
docker compose exec -T redmine-db mysqldump -uroot -p${REDMINE_ROOT_PW} redmine \
  | gzip > backups/redmine_$(date +%F_%H%M).sql.gz

# Nextcloud
docker compose exec -T nextcloud-db mysqldump -uroot -p${NEXTCLOUD_ROOT_PW} nextcloud \
  | gzip > backups/nextcloud_$(date +%F_%H%M).sql.gz

# Mautic
docker compose exec -T mautic-db mysqldump -uroot -p${MAUTIC_ROOT_PW} ma u t i c \
  | gzip > backups/mautic_$(date +%F_%H%M).sql.gz
```

**Dati (volumi)**

```bash
# Esempi tar; esegui uno per volta in base al servizio che aggiorni
docker run --rm -v nextcloud-data:/data -v $(pwd)/backups:/backups alpine \
  sh -c "cd /data && tar -czf /backups/nextcloud-data_$(date +%F_%H%M).tgz ."

docker run --rm -v redmine-data:/data -v $(pwd)/backups:/backups alpine \
  sh -c "cd /data && tar -czf /backups/redmine-files_$(date +%F_%H%M).tgz ."

docker run --rm -v mattermost_app:/data -v $(pwd)/backups:/backups alpine \
  sh -c "cd /data && tar -czf /backups/mattermost-data_$(date +%F_%H%M).tgz ."
```

> Tip: conserva **almeno** l’ultimo dump “buono” offsite.

---

## 3) Sequenza di upgrade per servizio

> Sostituisci `--profile prod` con `--profile local` se stai operando in dev.
> In **prod** fai prima manutenzione/annuncio, poi esegui.

### 3.A Nextcloud (32.x → 32.y)

1. **Maintenance mode ON**:

```bash
docker compose exec nextcloud bash -lc 'sudo -u www-data php occ maintenance:mode --on'
```

2. **Pull & recreate** (solo Nextcloud):

```bash
docker compose pull nextcloud
docker compose up -d nextcloud
```

3. **Verifica e migrazioni**:

```bash
docker compose logs -f nextcloud | sed -n '1,200p'
docker compose exec nextcloud bash -lc 'sudo -u www-data php occ upgrade'
docker compose exec nextcloud bash -lc 'sudo -u www-data php occ db:add-missing-indices || true'
docker compose exec nextcloud bash -lc 'sudo -u www-data php occ maintenance:repair || true'
```

4. **Maintenance mode OFF**:

```bash
docker compose exec nextcloud bash -lc 'sudo -u www-data php occ maintenance:mode --off'
```

5. **Smoke test rapido**:

* `https://drive.tuodominio.tld/status.php` restituisce JSON e `installed: true`
* Upload file, condividi, anteprima.

**Rollback**:

```bash
docker compose down nextcloud
# re-pin a versione precedente (nel compose), poi:
docker compose up -d nextcloud
# Se serve, restore DB e files dai backup
```

---

### 3.B MariaDB (10.11.x → 10.11.y) per servizi MySQL/MariaDB

> Redmine/Nextcloud/Mautic usano 10.11 LTS. Aggiorna **db prima** delle app solo se la app richiede esplicitamente; altrimenti patch minore è safe.

1. **Backup DB** già fatto (2.1).
2. **Pull & recreate** (es. nextcloud-db):

```bash
docker compose pull nextcloud-db
docker compose up -d nextcloud-db
docker compose logs -f nextcloud-db
```

3. **Check**:

```bash
docker compose exec nextcloud-db mysql -uroot -p${NEXTCLOUD_ROOT_PW} -e "SELECT VERSION();"
```

4. **Verifica app** (vedi 3.A per Nextcloud, 3.D per Mautic, 3.C per Redmine).

**Rollback**: ripin versione precedente nel compose e riparti; in casi rari restore dump.

---

### 3.C Redmine (6.1.x)

1. **Pull & recreate**:

```bash
docker compose pull redmine
docker compose up -d redmine
```

2. **Migrazioni DB** (se l’immagine non le esegue automaticamente):

```bash
docker compose exec redmine bash -lc 'bundle exec rake db:migrate RAILS_ENV=production'
docker compose exec redmine bash -lc 'bundle exec rake redmine:plugins:migrate RAILS_ENV=production || true'
```

3. **Rebuild search indices** (se usi plugin indicizzati):

```bash
docker compose exec redmine bash -lc 'bundle exec rake redmine:rebuild_full_text_index RAILS_ENV=production || true'
```

4. **Smoke test**:

* Login admin, apri una issue, invia una notifica email di prova.

**Rollback**: re-pin immagine precedente e riavvio. Ripristino DB solo se necessario.

---

### 3.D Mautic (5-apache, minor update)

1. **Pull & recreate**:

```bash
docker compose pull mautic
docker compose up -d mautic
```

2. **Migrazioni**:

```bash
docker compose exec mautic bash -lc 'php bin/console doctrine:migrations:migrate -n || true'
docker compose exec mautic bash -lc 'php bin/console cache:clear || true'
```

3. **Cron** (se li gestisci esternamente, ricordati di riattivarli dopo il test).

4. **Smoke test**:

* Login, apri “System Info”, invia email test.

---

### 3.E Mattermost (10.7.x)

> Versioni MM possono includere migrazioni DB (Postgres). Tenere copia del DB è fondamentale.

1. **Annuncio manutenzione** su canale, poi:

```bash
docker compose pull mattermost
docker compose up -d mattermost
docker compose logs -f mattermost
```

2. **Health**:

```bash
curl -s http://localhost:8065/api/v4/system/ping | jq
```

3. **Smoke test**:

* Login, invio messaggio, caricamento file, plugin attivi.

**Rollback**: re-pin immagine precedente + restore DB se servisse.

---

### 3.F n8n (1.101.x)

1. **Pull & recreate**:

```bash
docker compose pull n8n
docker compose up -d n8n
```

2. **Health**:

```bash
curl -f http://localhost:5678/healthz || exit 1
```

3. **Smoke test**:

* Apri UI, esegui un workflow di prova, verifica credenziali.

---

### 3.G Django app (immagine custom)

1. Aggiorna **requirements** e **Dockerfile** (se necessario).
2. **Build & up**:

```bash
docker compose build django
docker compose up -d django
docker compose exec -T django python manage.py migrate --noinput
```

3. **Smoke test**:

* Login admin, una rotte pubblica, webhook di Stripe in “test”.

---

### 3.H Odoo (patch)

1. **Pull & recreate**:

```bash
docker compose pull odoo
docker compose up -d odoo
```

2. **Check login** e funzioni base.
3. Se il salto richiede migrazioni maggiori, considera strumenti tipo **OpenUpgrade** (project separato).

---

## 4) Hardening e rifiniture post-upgrade

* **Caddy (prod)**: verifica headers (HSTS ecc.) con `curl -I https://dominio`.
* **Log**: assicurati che non esplodano con nuovi formati; imposta rotation se serve.
* **Backup**: esegui **un backup completo** dopo l’upgrade riuscito (nuovo “restore point”).

---

## 5) Rollback rapido (schema generico)

1. Re-pin immagine **precedente** nel `docker-compose.yml`.
2. `docker compose up -d <servizio>`
3. Se l’app non parte o ha schema incompatibile:

   * **Stop** servizio applicativo.
   * **Restore DB** dal dump (Postgres `pg_restore`, MariaDB `mysql`).
   * **Restore files** dal tar/tgz del volume se necessario.
4. Riavvia, smoke test.

---

## 6) Comandi utili (riassunto)

```bash
# Pull selettivo
docker compose pull nextcloud

# Up senza toccare altri servizi
docker compose up -d nextcloud

# Log streaming
docker compose logs -f nextcloud

# Health sintetico (se definito nel compose)
docker inspect --format='{{json .State.Health}}' $(docker compose ps -q nextcloud) | jq

# Exec veloci
docker compose exec nextcloud bash -lc 'sudo -u www-data php occ status'
docker compose exec redmine bash -lc 'bundle exec rake db:migrate RAILS_ENV=production'
docker compose exec mautic bash -lc 'php bin/console doctrine:migrations:migrate -n'
```

---

## 7) Mini checklist per ogni upgrade (stampala 😉)

* [ ] Annuncio finestra manutenzione (prod).
* [ ] Backup DB + dati del servizio coinvolto.
* [ ] `docker compose pull <servizio>`
* [ ] `docker compose up -d <servizio>`
* [ ] Esegui **migrazioni** (occ/rake/console).
* [ ] **Smoke test** funzionale.
* [ ] Disattiva manutenzione.
* [ ] Esegui **backup post-upgrade**.
* [ ] Pronto il **piano di rollback** (immagine precedente + dump).

---

Se vuoi, posso fornirti anche uno **script bash `upgrade.sh`** parametrico (es. `./upgrade.sh nextcloud prod`) che incapsula questi passi per ogni servizio, con colori, check ed exit codes puliti. Dimmi quali servizi vuoi includere per primi e te lo scrivo subito.
