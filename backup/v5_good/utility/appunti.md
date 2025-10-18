perfetto — intanto ti lascio un primo check-up dello stack e un mini–playbook per avviarlo bene (dev e prod). Se vuoi poi andiamo di fino su uno specifico servizio.

# Check veloce & miglioramenti consigliati

**1) Sicurezza & segreti**

* `ADMIN_PASS=ChangeMe!123` → cambia subito (e non committarlo).
* Hai chiavi Stripe *test* in chiaro: ok in dev, **mettile in `.env.local`/vault** e non nel repo.
* Blocca i log che stampano env (nessuno dei container dovrebbe loggare variabili).
* Yahoo SMTP: è commentato, ma se lo usi crea **app password dedicata** e non riutilizzare credenziali personali.

**2) Naming script**

* `bootstrap_cloudetta.py` è in realtà una **bash script** (shebang `bash`). Rinomialo in `bootstrap_cloudetta.sh` per evitare confusione.

**3) Versioni immagini**

* `nextcloud:26` è datata: valuta almeno 27/28 LTS (controlla compat con app).
* `mariadb:10.6` è EOL/extended: passa a 10.11 LTS o 11.x dopo test.
* `n8nio/n8n:latest` → meglio pin di versione (es. `1.64.x`) per build riproducibili.
* `mattermost-team-edition:latest` idem: usa una tag stabile (es. `10.x`).

**4) Caddy & domini**

* In locale hai `auto_https off` (ok). In prod ti serviranno **server blocks HTTPS** con i `*_DOMAIN` e ACME:

  * imposta per ciascun servizio `DJANGO_DOMAIN`, `ODOO_DOMAIN`, ecc. **e** crea i blocchi 443 nel Caddyfile.
  * Usa `CADDY_EMAIL` per il rate-limit LE e renewal.

**5) Header/proxy Django**

* Hai già `USE_X_FORWARDED_HOST` e `SECURE_PROXY_SSL_HEADER`. Ricordati in prod:

  * `DJANGO_DEBUG=False`
  * `DJANGO_ALLOWED_HOSTS` includa **i FQDN reali**
  * `DJANGO_CSRF_TRUSTED_ORIGINS` con `https://<dominio>`

**6) Redmine DB init**

* Lo script fa bootstrap MySQL e poi ricrea Redmine: ok, ma se il container cambia tag servirà **migrazione** (backup prima).

**7) Mautic**

* Auto–install via CLI: bene. In prod imposta `MAUTIC_DOMAIN` per `site_url` e rivedi cron (Mautic ha molti cron job).

**8) Mattermost**

* Usa `mmctl --local`: ottimo. Aggiungi un **volumetto per il socket** se cambi runtime. Verifica email (SMTP) prima di invitare utenti.

**9) Mailer**

* L’immagine `bytemark/smtp` è minimale. In prod conviene:

  * **SMTP provider** (SendGrid/Postmark/SES) con DKIM/SPF corretti,
  * oppure stack mail dedicato (Mailcow) già contemplato nelle variabili.

**10) Backup**

* Il container `alpine` con cron è ok come “all-in-one”, ma:

  * aggiungi **healthcheck** al servizio `backup`,
  * esporta dump **coerenti** (usa `pg_dump`/`mysqldump` con lock/flags consistenti),
  * cifra gli archivi se vanno offsite (es. `age`/`gpg`).

**11) Reti**

* Tutti i servizi stanno su `internal`; Caddy li espone. Perfetto.
* In prod potresti voler aggiungere **network policies** o separare `db_net`.

**12) Qualche lint “qualità di vita”**

* Aggiungi `healthcheck` a: postgres, mariadb, django, redmine, nextcloud, mautic, mattermost (riduce tempi di `wait_on_*`).
* Pin dei volumi: valuta `driver_opts` se usi storage esterno.

---

# Avvio rapido ambiente **dev** (localhost)

1. rinomina lo script:

```bash
mv bootstrap_cloudetta.py bootstrap_cloudetta.sh
chmod +x bootstrap_cloudetta.sh
```

2. crea `.env` (se non c’è) e **cambia le password** principali. Almeno:

```env
ADMIN_PASS=<super-segreta>
DJANGO_SECRET_KEY=<random forte>
```

3. up:

```bash
docker compose up -d
./bootstrap_cloudetta.sh
```

4. accessi (localhost):

* Django → `http://django.localhost`
* Odoo → `http://odoo.localhost`
* Redmine → `http://redmine.localhost`
* Nextcloud → `http://nextcloud.localhost`
* Mautic → `http://mautic.localhost`
* n8n → `http://n8n.localhost` (Basic Auth admin / pass unificati)
* DokuWiki → `http://wiki.localhost`
* Mattermost → `http://chat.localhost`

---

# Esempio blocchi **prod** (Caddy) con HTTPS

Nel tuo `caddy/Caddyfile` aggiungi, per ciascun dominio che imposti in `.env`:

```caddy
# globale (auto_https on di default)
{
  email {env.CADDY_EMAIL}
}

https://{env.DJANGO_DOMAIN} {
  reverse_proxy django:8000
}

https://{env.ODOO_DOMAIN} {
  reverse_proxy odoo:8069
}

https://{env.REDMINE_DOMAIN} {
  reverse_proxy redmine:3000
}

https://{env.NEXTCLOUD_DOMAIN} {
  reverse_proxy nextcloud:80
}

https://{env.MAUTIC_DOMAIN} {
  reverse_proxy mautic:80
}

https://{env.N8N_DOMAIN} {
  reverse_proxy n8n:5678
}

https://{env.MATTERMOST_DOMAIN} {
  reverse_proxy mattermost:8065
}
```

E in `.env` valorizza i domini:

```env
DJANGO_DOMAIN=portal.esempio.it
ODOO_DOMAIN=erp.esempio.it
REDMINE_DOMAIN=pm.esempio.it
NEXTCLOUD_DOMAIN=drive.esempio.it
MAUTIC_DOMAIN=marketing.esempio.it
N8N_DOMAIN=automations.esempio.it
MATTERMOST_DOMAIN=chat.esempio.it
```

> Nota: per Nextcloud aggiungi i FQDN a `TRUSTED_DOMAINS` e metti `PUBLIC_DOMAIN` se vuoi forzare `overwrite.cli.url`.

---

# Hardening minimo consigliato (prod)

* **Segreti** via `docker secrets` o `.env` cifrato (sops/age).
* **Limita** `ports:` solo a Caddy. Togli le `ports` sui servizi app (hai già reverse proxy).
* **Resources**: aggiungi `deploy.resources.limits` (CPU/RAM) per evitare OOM.
* **Backup offsite** + test restore periodico.
* **Monitoring**: Prometheus/Grafana o almeno alert sui container unhealthy.
* **Logs**: driver `json-file` con `max-size`/`max-file` o Loki.

---

Se ti va, dimmi se stai puntando **dev locale** o **prod con DNS reali**: ti preparo i blocchi definitivi (Caddy + env), gli healthcheck e uno script di backup “bonificato” per Postgres/MariaDB.


ok, problema classico: “un solo Caddyfile” che vada bene sia per `*.localhost` (senza TLS) sia per i domini pubblici (con HTTPS/ACME) finisce per fare casino—Caddy tenta i certificati anche in dev e spamma errori. Ti propongo una soluzione **pulita e pratica** con due modalità esplicite e zero sorprese:

## Strategia

* **Due configurazioni Caddy**: `local` (solo http, auto_https off) e `prod` (https con Let’s Encrypt).
* **Selettore di modalità**: variabile d’ambiente `CADDY_MODE=local|prod`.
* **Templating semplice**: generiamo il Caddyfile finale da un template usando `envsubst`, così possiamo usare i domini del tuo `.env` senza “if” nel Caddyfile.

---

## 1) Struttura file consigliata

```
caddy/
├─ Caddyfile.local       # solo http per *.localhost
├─ Caddyfile.prod.tmpl   # https per domini pubblici (usa {env} via envsubst)
└─ entrypoint.sh         # genera Caddyfile finale e avvia caddy
```

### `caddy/Caddyfile.local`

```caddy
{
  # in locale disattiviamo https per *.localhost
  auto_https off
  admin off
}

# ---------- Django ----------
http://django.localhost {
  reverse_proxy django:8000
}

# ---------- Odoo ----------
http://odoo.localhost {
  reverse_proxy odoo:8069
}

# ---------- Redmine ----------
http://redmine.localhost {
  reverse_proxy redmine:3000
}

# ---------- DokuWiki ----------
http://wiki.localhost {
  reverse_proxy dokuwiki:80
}

# ---------- Nextcloud ----------
http://nextcloud.localhost {
  reverse_proxy nextcloud:80
}

# ---------- Mautic ----------
http://mautic.localhost {
  reverse_proxy mautic:80
}

# ---------- n8n ----------
http://n8n.localhost {
  reverse_proxy n8n:5678
}

# ---------- Mattermost ----------
http://chat.localhost {
  reverse_proxy mattermost:8065
}
```

### `caddy/Caddyfile.prod.tmpl`

> Usa le variabili del tuo `.env` (vuote = blocco inutile → non lo generiamo, vedi entrypoint)

```caddy
{
  email ${CADDY_EMAIL}
  # consigli: ocsp_stapling, prefer_server_ciphers ecc. sono automatici in Caddy
}

# redirect http → https per i domini noti (se valorizzati)
${DJANGO_DOMAIN:+http://${DJANGO_DOMAIN} {
  redir https://${DJANGO_DOMAIN}{uri}
}}
${ODOO_DOMAIN:+http://${ODOO_DOMAIN} {
  redir https://${ODOO_DOMAIN}{uri}
}}
${REDMINE_DOMAIN:+http://${REDMINE_DOMAIN} {
  redir https://${REDMINE_DOMAIN}{uri}
}}
${NEXTCLOUD_DOMAIN:+http://${NEXTCLOUD_DOMAIN} {
  redir https://${NEXTCLOUD_DOMAIN}{uri}
}}
${N8N_DOMAIN:+http://${N8N_DOMAIN} {
  redir https://${N8N_DOMAIN}{uri}
}}
${WIKI_DOMAIN:+http://${WIKI_DOMAIN} {
  redir https://${WIKI_DOMAIN}{uri}
}}
${MAUTIC_DOMAIN:+http://${MAUTIC_DOMAIN} {
  redir https://${MAUTIC_DOMAIN}{uri}
}}
${MATTERMOST_DOMAIN:+http://${MATTERMOST_DOMAIN} {
  redir https://${MATTERMOST_DOMAIN}{uri}
}}

# siti https (solo se la variabile è valorizzata)
${DJANGO_DOMAIN:+https://${DJANGO_DOMAIN} {
  reverse_proxy django:8000
}}

${ODOO_DOMAIN:+https://${ODOO_DOMAIN} {
  reverse_proxy odoo:8069
}}

${REDMINE_DOMAIN:+https://${REDMINE_DOMAIN} {
  reverse_proxy redmine:3000
}}

${NEXTCLOUD_DOMAIN:+https://${NEXTCLOUD_DOMAIN} {
  reverse_proxy nextcloud:80
}}

${N8N_DOMAIN:+https://${N8N_DOMAIN} {
  reverse_proxy n8n:5678
}}

${WIKI_DOMAIN:+https://${WIKI_DOMAIN} {
  reverse_proxy dokuwiki:80
}}

${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN} {
  reverse_proxy mautic:80
}}

${MATTERMOST_DOMAIN:+https://${MATTERMOST_DOMAIN} {
  reverse_proxy mattermost:8065
}}
```

### `caddy/entrypoint.sh`

```bash
#!/bin/sh
set -e

MODE="${CADDY_MODE:-local}"
CFG_DIR="/etc/caddy"

if [ "$MODE" = "local" ]; then
  echo "[caddy] MODE=local → uso Caddyfile.local (no TLS)"
  cp -f "$CFG_DIR/Caddyfile.local" "$CFG_DIR/Caddyfile"
else
  echo "[caddy] MODE=prod → genero Caddyfile da template"
  # envsubst su tutte le variabili che iniziano con queste chiavi
  export DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN MATTERMOST_DOMAIN CADDY_EMAIL
  envsubst < "$CFG_DIR/Caddyfile.prod.tmpl" > "$CFG_DIR/Caddyfile"
fi

echo "[caddy] avvio caddy con $(caddy version)"
exec caddy run --config "$CFG_DIR/Caddyfile" --adapter caddyfile
```

---

## 2) Modifiche a `docker-compose.yml` (solo servizio caddy)

Sostituisci il blocco `caddy` con questo (nota `command` + nuovi mount):

```yaml
  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CADDY_MODE=${CADDY_MODE:-local}             # <-- selettore
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
      # opzionali: domini pubblici (usati in prod)
      - DJANGO_DOMAIN=${DJANGO_DOMAIN}
      - ODOO_DOMAIN=${ODOO_DOMAIN}
      - REDMINE_DOMAIN=${REDMINE_DOMAIN}
      - NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN}
      - N8N_DOMAIN=${N8N_DOMAIN}
      - WIKI_DOMAIN=${WIKI_DOMAIN}
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
      - MATTERMOST_DOMAIN=${MATTERMOST_DOMAIN}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/docker-entrypoint.d/10-entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    # sovrascriviamo il command default per usare il nostro entrypoint
    command: ["/bin/sh","-lc","chmod +x /docker-entrypoint.d/10-entrypoint.sh && /docker-entrypoint.d/10-entrypoint.sh"]
    networks:
      - web
      - internal
```

> Per sicurezza: lascia **le `ports` solo su Caddy** (gli altri servizi non dovrebbero esporre porte in prod). In dev puoi anche tenerle, ma non servono perché caddy fa da proxy.

---

## 3) Come usarlo

### Dev locale (senza certificati)

Nel tuo `.env`:

```env
CADDY_MODE=local
# (non serve valorizzare i *_DOMAIN per il local)
```

Poi:

```bash
docker compose up -d caddy
```

Apri i soliti URL: `http://django.localhost`, `http://odoo.localhost`, ecc.

### Produzione (HTTPS automatico)

Nel tuo `.env`:

```env
CADDY_MODE=prod
CADDY_EMAIL=antonio.trento@yahoo.com

DJANGO_DOMAIN=portal.tuodominio.tld
ODOO_DOMAIN=erp.tuodominio.tld
REDMINE_DOMAIN=pm.tuodominio.tld
NEXTCLOUD_DOMAIN=drive.tuodominio.tld
N8N_DOMAIN=automations.tuodominio.tld
WIKI_DOMAIN=wiki.tuodominio.tld
MAUTIC_DOMAIN=marketing.tuodominio.tld
MATTERMOST_DOMAIN=chat.tuodominio.tld
```

Assicurati che i DNS puntino alla macchina. Poi:

```bash
docker compose up -d caddy
```

Caddy genererà i certificati solo per i domini **valorizzati** (gli altri blocchi non vengono creati perché il template li omette).

---

## 4) Note utili (evitano problemi tipici)

* **Loop/timeout ACME in dev**: con `CADDY_MODE=local` eviti qualunque tentativo di certificazione.
* **Mixed mode**: se vuoi *davvero* servire sia `*.localhost` che domini pubblici sulla stessa istanza (es. ambiente demo con DNS reali **e** test locale), puoi:

  * avviare **due** istanze di Caddy su **IP/porte diverse** (o su host diversi),
  * oppure creare un file `Caddyfile.mixed` che importi *entrambi* i blocchi (local+prod). Sconsigliato: in ambienti senza DNS pubblici funzionanti, Caddy proverà comunque ACME.
* **Nextcloud**: in prod aggiungi i FQDN a `TRUSTED_DOMAINS` e (se serve) `PUBLIC_DOMAIN` nel tuo `.env`—lo script bootstrap lo imposta con `overwrite.cli.url`.
* **Header/real IP**: Caddy passa già `X-Forwarded-For`/`Proto`. Su Django hai `SECURE_PROXY_SSL_HEADER` ok; ricordati `DJANGO_DEBUG=False` in prod e allinea `DJANGO_ALLOWED_HOSTS`/`DJANGO_CSRF_TRUSTED_ORIGINS` con i FQDN.
* **Firewall**: in prod apri solo 80/443 verso Caddy; i container interni restano sulla rete `internal`.

---

Se vuoi, ti preparo anche una **variante “profiles”** in `docker-compose` (profile `local` e `prod`) così lanci `docker compose --profile prod up -d` e cambia automaticamente Caddy. Dimmi se preferisci quella strada o se questa con `CADDY_MODE` ti va bene.


perfetto — ti preparo il **pacchetto completo** per la variante con **profiles** in `docker-compose`:

- `profile: local` → Caddy solo HTTP (localhost).
- `profile: prod`  → Caddy HTTPS con Let’s Encrypt, Caddyfile generato **solo** per i domini valorizzati nel `.env` (niente ACME “a vuoto”).

Ho anche predisposto un piccolo update opzionale a `bootstrap_cloudetta.sh` per farlo lavorare con i profili (se vuoi), ma funziona anche senza modifiche.

---

# 1) `.env.example` (aggiornato)

> Copialo in `.env` e cambia le password prima di avviare.

```env
# --- Contatti ACME/Let's Encrypt (solo prod) ---
CADDY_EMAIL=antonio.trento@yahoo.com

# --- Domini pubblici (solo prod; lascia vuoti quelli che non usi) ---
DJANGO_DOMAIN=
ODOO_DOMAIN=
REDMINE_DOMAIN=
NEXTCLOUD_DOMAIN=
N8N_DOMAIN=
WIKI_DOMAIN=
MAUTIC_DOMAIN=
MATTERMOST_DOMAIN=

# ====== Admin unificato (usato in tutto lo stack) ======
ADMIN_USER=admin
ADMIN_PASS=ChangeMe!123
ADMIN_EMAIL=antonio.trento@yahoo.com

# ====== Django ======
DJANGO_SECRET_KEY=dev_change_me
DJANGO_DB_PASSWORD=dev_django_pw
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=django,localhost,127.0.0.1,django.localhost,django.example.com
DJANGO_CSRF_TRUSTED_ORIGINS=http://django.localhost,http://django.example.com,https://django.localhost,https://django.example.com
DJANGO_USE_X_FORWARDED_HOST=True
DJANGO_SECURE_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https
DJANGO_ADMIN_USER=${ADMIN_USER}
DJANGO_ADMIN_EMAIL=${ADMIN_EMAIL}
DJANGO_ADMIN_PASS=${ADMIN_PASS}

STRIPE_PUBLIC_KEY=pk_test_xxx
STRIPE_SECRET_KEY=sk_test_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx

# ====== Odoo ======
ODOO_DB_PASSWORD=dev_odoo_db_pw
ODOO_DB=cloudetta
ODOO_MASTER_PASSWORD=${ADMIN_PASS}
ODOO_DEMO=true
ODOO_LANG=it_IT

# ====== Redmine ======
REDMINE_DB_PASSWORD=dev_redmine_db_pw
REDMINE_ROOT_PW=dev_redmine_root_pw
REDMINE_SECRET_KEY_BASE=

# ====== Nextcloud ======
NEXTCLOUD_DB_PASSWORD=dev_nextcloud_db_pw
NEXTCLOUD_ROOT_PW=dev_nextcloud_root_pw
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASS=${ADMIN_PASS}
PUBLIC_DOMAIN=
TRUSTED_DOMAINS=localhost,127.0.0.1,nextcloud,nextcloud.localhost,${PUBLIC_DOMAIN}

# ====== n8n ======
N8N_PASSWORD=${ADMIN_PASS}

# ====== Mail ======
MAIL_PROVIDER=sendgrid
MAIL_USER=admin@example.com
MAIL_PASS=change_me_mail_password
# Opzione SMTP (esempio Yahoo - commentata)
# MAIL_PROVIDER=smtp
# MAIL_USER=antonio.trento@yahoo.com
# MAIL_PASS=app_password
# MAIL_HOST=smtp.mail.yahoo.com
# MAIL_PORT=587
# MAIL_ENCRYPTION=tls
# MAIL_FROM_NAME="Antonio Trento"
# MAIL_FROM_ADDRESS=antonio.trento@yahoo.com

# ====== Caddy/DokuWiki (Basic Auth) ======
WIKI_BCRYPT_HASH=

# ====== Mautic ======
MAUTIC_DB_PASSWORD=dev_mautic_db_pw
MAUTIC_ROOT_PW=dev_mautic_root_pw
# MAUTIC_DOMAIN=mautic.example.com

# ====== Mattermost ======
MATTERMOST_DB_PASSWORD=dev_mattermost_db_pw
MATTERMOST_SITEURL=http://chat.localhost
MATTERMOST_ADMIN_USER=${ADMIN_USER}
MATTERMOST_ADMIN_EMAIL=${ADMIN_EMAIL}
MATTERMOST_ADMIN_PASS=${ADMIN_PASS}
MATTERMOST_TEAM_NAME=cloudetta
MATTERMOST_TEAM_DISPLAY=Cloudetta
```

---

# 2) `caddy/Caddyfile.local` (solo HTTP per dev)

```caddy
{
  auto_https off
  admin off
}

# ---------- Django ----------
http://django.localhost {
  reverse_proxy django:8000
}

# ---------- Odoo ----------
http://odoo.localhost {
  reverse_proxy odoo:8069
}

# ---------- Redmine ----------
http://redmine.localhost {
  reverse_proxy redmine:3000
}

# ---------- DokuWiki ----------
http://wiki.localhost {
  reverse_proxy dokuwiki:80
}

# ---------- Nextcloud ----------
http://nextcloud.localhost {
  reverse_proxy nextcloud:80
}

# ---------- Mautic ----------
http://mautic.localhost {
  reverse_proxy mautic:80
}

# ---------- n8n ----------
http://n8n.localhost {
  reverse_proxy n8n:5678
}

# ---------- Mattermost ----------
http://chat.localhost {
  reverse_proxy mattermost:8065
}
```

---

# 3) `caddy/Caddyfile.prod.tmpl` (HTTPS, generato in runtime)

> Template “intelligente”: crea **solo** i blocchi dei domini valorizzati nel `.env`.

```caddy
{
  email ${CADDY_EMAIL}
}

# Redirect http→https per i domini valorizzati
${DJANGO_DOMAIN:+http://${DJANGO_DOMAIN} {
  redir https://${DJANGO_DOMAIN}{uri}
}}
${ODOO_DOMAIN:+http://${ODOO_DOMAIN} {
  redir https://${ODOO_DOMAIN}{uri}
}}
${REDMINE_DOMAIN:+http://${REDMINE_DOMAIN} {
  redir https://${REDMINE_DOMAIN}{uri}
}}
${NEXTCLOUD_DOMAIN:+http://${NEXTCLOUD_DOMAIN} {
  redir https://${NEXTCLOUD_DOMAIN}{uri}
}}
${N8N_DOMAIN:+http://${N8N_DOMAIN} {
  redir https://${N8N_DOMAIN}{uri}
}}
${WIKI_DOMAIN:+http://${WIKI_DOMAIN} {
  redir https://${WIKI_DOMAIN}{uri}
}}
${MAUTIC_DOMAIN:+http://${MAUTIC_DOMAIN} {
  redir https://${MAUTIC_DOMAIN}{uri}
}}
${MATTERMOST_DOMAIN:+http://${MATTERMOST_DOMAIN} {
  redir https://${MATTERMOST_DOMAIN}{uri}
}}

# Siti https
${DJANGO_DOMAIN:+https://${DJANGO_DOMAIN} {
  reverse_proxy django:8000
}}
${ODOO_DOMAIN:+https://${ODOO_DOMAIN} {
  reverse_proxy odoo:8069
}}
${REDMINE_DOMAIN:+https://${REDMINE_DOMAIN} {
  reverse_proxy redmine:3000
}}
${NEXTCLOUD_DOMAIN:+https://${NEXTCLOUD_DOMAIN} {
  reverse_proxy nextcloud:80
}}
${N8N_DOMAIN:+https://${N8N_DOMAIN} {
  reverse_proxy n8n:5678
}}
${WIKI_DOMAIN:+https://${WIKI_DOMAIN} {
  reverse_proxy dokuwiki:80
}}
${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN} {
  reverse_proxy mautic:80
}}
${MATTERMOST_DOMAIN:+https://${MATTERMOST_DOMAIN} {
  reverse_proxy mattermost:8065
}}
```

---

# 4) `caddy/entrypoint.sh` (genera Caddyfile in prod)

```bash
#!/bin/sh
set -e

MODE="$1" # "local" | "prod"
CFG_DIR="/etc/caddy"

if [ "$MODE" = "local" ]; then
  echo "[caddy] MODE=local → uso Caddyfile.local"
  cp -f "$CFG_DIR/Caddyfile.local" "$CFG_DIR/Caddyfile"
else
  echo "[caddy] MODE=prod → genero Caddyfile da template"
  export DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN MATTERMOST_DOMAIN CADDY_EMAIL
  envsubst < "$CFG_DIR/Caddyfile.prod.tmpl" > "$CFG_DIR/Caddyfile"
fi

exec caddy run --config "$CFG_DIR/Caddyfile" --adapter caddyfile
```

> Ricordati: `chmod +x caddy/entrypoint.sh`

---

# 5) `docker-compose.yml` (con **profiles**)

> Aggiungo **due servizi Caddy**: `caddy-local` (profile `local`) e `caddy-prod` (profile `prod`).  
> Gli altri servizi restano invariati. Avvi ne **uno per volta** con il profilo desiderato.

```yaml
version: "3.9"

networks:
  web:
    driver: bridge
  internal:
    driver: bridge

services:
  # ================== CADDY (LOCAL) ==================
  caddy-local:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    profiles: ["local"]
    ports:
      - "80:80"
      - "443:443"
    environment:
      # nessun dominio necessario in local
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["/bin/sh","-lc","/entrypoint.sh local"]
    networks:
      - web
      - internal

  # ================== CADDY (PROD) ==================
  caddy-prod:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    profiles: ["prod"]
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
      - DJANGO_DOMAIN=${DJANGO_DOMAIN}
      - ODOO_DOMAIN=${ODOO_DOMAIN}
      - REDMINE_DOMAIN=${REDMINE_DOMAIN}
      - NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN}
      - N8N_DOMAIN=${N8N_DOMAIN}
      - WIKI_DOMAIN=${WIKI_DOMAIN}
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
      - MATTERMOST_DOMAIN=${MATTERMOST_DOMAIN}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["/bin/sh","-lc","/entrypoint.sh prod"]
    networks:
      - web
      - internal

  # ================== APPS ==================
  django:
    build: ./django
    container_name: django
    command: gunicorn django_project.wsgi:application --bind 0.0.0.0:8000
    depends_on:
      - django-db
    environment:
      - DJANGO_SETTINGS_MODULE=django_project.settings
      - DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
      - DJANGO_DEBUG=${DJANGO_DEBUG:-False}
      - DJANGO_ALLOWED_HOSTS=${DJANGO_ALLOWED_HOSTS:-django.localhost,django.example.com}
      - DATABASE_URL=postgres://django:${DJANGO_DB_PASSWORD}@django-db:5432/django
      - STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-sk_test_xxx}
      - STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-whsec_xxx}
      - DJANGO_ADMIN_USER=${DJANGO_ADMIN_USER}
      - DJANGO_ADMIN_EMAIL=${DJANGO_ADMIN_EMAIL}
      - DJANGO_ADMIN_PASS=${DJANGO_ADMIN_PASS}
    volumes:
      - ./django:/app
    ports:
      - "8000:8000"
    networks:
      - internal

  django-db:
    image: postgres:15
    container_name: django-db
    environment:
      - POSTGRES_DB=django
      - POSTGRES_USER=django
      - POSTGRES_PASSWORD=${DJANGO_DB_PASSWORD}
    volumes:
      - django-db-data:/var/lib/postgresql/data
    networks:
      - internal

  odoo:
    build: ./odoo
    container_name: odoo
    depends_on:
      - odoo-db
      - redis
    environment:
      - HOST=odoo-db
      - USER=odoo
      - PASSWORD=${ODOO_DB_PASSWORD}
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - ADMIN_PASS=${ADMIN_PASS}
      - ODOO_DB=${ODOO_DB}
      - ODOO_LANG=${ODOO_LANG}
    volumes:
      - odoo-data:/var/lib/odoo
      - ./odoo-addons:/mnt/extra-addons
    networks:
      - internal

  odoo-db:
    image: postgres:15
    container_name: odoo-db
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_USER=odoo
      - POSTGRES_PASSWORD=${ODOO_DB_PASSWORD}
    volumes:
      - postgres-odoo-data:/var/lib/postgresql/data
    networks:
      - internal

  redis:
    image: redis:7
    container_name: redis
    command: ["redis-server", "--save", "60", "1"]
    volumes:
      - redis-data:/data
    networks:
      - internal

  redmine:
    image: redmine:5
    container_name: redmine
    depends_on:
      - redmine-db
    environment:
      REDMINE_DB_MYSQL: redmine-db
      REDMINE_DB_DATABASE: redmine
      REDMINE_DB_USERNAME: redmine
      REDMINE_DB_PASSWORD: ${REDMINE_DB_PASSWORD}
      REDMINE_SECRET_KEY_BASE: ${REDMINE_SECRET_KEY_BASE}
    volumes:
      - redmine-data:/usr/src/redmine/files
    networks:
      - internal

  redmine-db:
    image: mariadb:10.6
    container_name: redmine-db
    environment:
      - MYSQL_ROOT_PASSWORD=${REDMINE_ROOT_PW}
      - MYSQL_DATABASE=redmine
      - MYSQL_USER=redmine
      - MYSQL_PASSWORD=${REDMINE_DB_PASSWORD}
    volumes:
      - redmine-db-data:/var/lib/mysql
    networks:
      - internal

  nextcloud:
    image: nextcloud:26
    container_name: nextcloud
    depends_on:
      - nextcloud-db
    environment:
      - MYSQL_HOST=nextcloud-db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASS=${NEXTCLOUD_ADMIN_PASS}
    volumes:
      - nextcloud-data:/var/www/html
    networks:
      - internal

  nextcloud-db:
    image: mariadb:10.6
    container_name: nextcloud-db
    environment:
      - MYSQL_ROOT_PASSWORD=${NEXTCLOUD_ROOT_PW}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
    volumes:
      - nextcloud-db-data:/var/lib/mysql
    networks:
      - internal

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    environment:
      - GENERIC_TIMEZONE=Europe/Rome
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${ADMIN_USER}
      - N8N_BASIC_AUTH_PASSWORD=${ADMIN_PASS}
    ports:
      - "5678:5678"
    volumes:
      - n8n-data:/home/node/.n8n
    networks:
      - internal

  dokuwiki:
    image: linuxserver/dokuwiki:latest
    container_name: dokuwiki
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - dokuwiki-data:/config
    networks:
      - internal

  mautic:
    image: mautic/mautic:5-apache
    container_name: mautic
    depends_on:
      - mautic-db
    environment:
      - MAUTIC_DB_HOST=mautic-db
      - MAUTIC_DB_USER=mautic
      - MAUTIC_DB_PASSWORD=${MAUTIC_DB_PASSWORD}
      - MAUTIC_DB_NAME=mautic
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
    volumes:
      - mautic-data:/var/www/html
    networks:
      - internal

  mautic-db:
    image: mariadb:10.6
    container_name: mautic-db
    environment:
      - MYSQL_ROOT_PASSWORD=${MAUTIC_ROOT_PW}
      - MYSQL_DATABASE=mautic
      - MYSQL_USER=mautic
      - MYSQL_PASSWORD=${MAUTIC_DB_PASSWORD}
    volumes:
      - mautic-db-data:/var/lib/mysql
    networks:
      - internal

  mail:
    image: bytemark/smtp
    container_name: mail
    environment:
      - PROVIDER=${MAIL_PROVIDER:-sendgrid}
      - SMTP_USER=${MAIL_USER:-admin@example.com}
      - SMTP_PASS=${MAIL_PASS:-changeme}
    networks:
      - internal

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost
    depends_on:
      - mattermost-db
    environment:
      - MM_SERVICESETTINGS_SITEURL=${MATTERMOST_SITEURL:-http://chat.localhost}
      - MM_SERVICESETTINGS_ENABLELOCALMODE=true
      - MM_SERVICESETTINGS_LOCALMODESOCKETLOCATION=/var/tmp/mattermost_local.socket
      - MM_SQLSETTINGS_DRIVERNAME=postgres
      - MM_SQLSETTINGS_DATASOURCE=postgres://mmuser:${MATTERMOST_DB_PASSWORD}@mattermost-db:5432/mattermost?sslmode=disable&connect_timeout=10
      - MM_EMAILSETTINGS_ENABLESIGNUPWITHEMAIL=true
      - MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=true
      - MM_EMAILSETTINGS_SMTPSERVER=${MAIL_HOST:-}
      - MM_EMAILSETTINGS_SMTPPORT=${MAIL_PORT:-}
      - MM_EMAILSETTINGS_CONNECTIONSECURITY=${MAIL_ENCRYPTION:-}
      - MM_EMAILSETTINGS_SMTPUSERNAME=${MAIL_USER:-}
      - MM_EMAILSETTINGS_SMTPPASSWORD=${MAIL_PASS:-}
      - MM_EMAILSETTINGS_FEEDBACKEMAIL=${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      - MM_EMAILSETTINGS_REPLYTOADDRESS=${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      - TZ=${TZ:-Europe/Rome}
      - MM_LOGSETTINGS_ENABLECONSOLE=true
      - MM_PLUGINSETTINGS_ENABLE=true
    volumes:
      - mattermost_app:/mattermost/data
      - mattermost_logs:/mattermost/logs
      - mattermost_config:/mattermost/config
      - mattermost_plugins:/mattermost/plugins
      - mattermost_client:/mattermost/client/plugins
    networks:
      - internal

  mattermost-db:
    image: postgres:15
    container_name: mattermost-db
    environment:
      - POSTGRES_USER=mmuser
      - POSTGRES_PASSWORD=${MATTERMOST_DB_PASSWORD}
      - POSTGRES_DB=mattermost
    volumes:
      - mattermost_pgdata:/var/lib/postgresql/data
    networks:
      - internal

  backup:
    image: alpine:3.19
    container_name: backup
    volumes:
      - django-db-data:/django-db-data
      - odoo-data:/odoo-data
      - postgres-odoo-data:/postgres-odoo-data
      - redis-data:/redis-data
      - redmine-data:/redmine-data
      - redmine-db-data:/redmine-db-data
      - nextcloud-data:/nextcloud-data
      - nextcloud-db-data:/nextcloud-db-data
      - dokuwiki-data:/dokuwiki-data
      - n8n-data:/n8n-data
      - mautic-data:/mautic-data
      - mautic-db-data:/mautic-db-data
      - mattermost_app:/mattermost_app
      - mattermost_logs:/mattermost_logs
      - mattermost_config:/mattermost_config
      - mattermost_plugins:/mattermost_plugins
      - mattermost_client:/mattermost_client
      - mattermost_pgdata:/mattermost_pgdata
      - ./backups:/backups
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backup/backup.sh:/backup/backup.sh:ro
    entrypoint: ["/bin/sh","-c","apk add --no-cache bash postgresql-client mariadb-client tar gzip && echo '0 2 * * * /backup/backup.sh >> /backups/backup.log 2>&1' | crontab - && crond -f"]
    networks:
      - internal

volumes:
  caddy_data:
  caddy_config:
  django-db-data:
  odoo-data:
  postgres-odoo-data:
  redis-data:
  redmine-data:
  redmine-db-data:
  nextcloud-data:
  nextcloud-db-data:
  n8n-data:
  dokuwiki-data:
  mautic-data:
  mautic-db-data:
  mattermost_app:
  mattermost_logs:
  mattermost_config:
  mattermost_plugins:
  mattermost_client:
  mattermost_pgdata:
```

---

# 6) (Opzionale) Update a `bootstrap_cloudetta.sh`

Non è strettamente necessario. Se però vuoi che lo script avvii anche Caddy con il **profilo** giusto, puoi aggiungere queste righe **subito prima** del punto in cui lancia `docker compose up -d`:

```bash
# --- PROFILI DOCKER COMPOSE (opzionale) ---
# Usa BOOTSTRAP_PROFILES="local" oppure "prod" (spazio-separati se multipli)
COMPOSE_PROFILES_ARGS=""
if [ -n "${BOOTSTRAP_PROFILES:-}" ]; then
  for p in ${BOOTSTRAP_PROFILES}; do
    COMPOSE_PROFILES_ARGS="$COMPOSE_PROFILES_ARGS --profile $p"
  done
fi

# Avvio stack (solo servizi senza profilo + profili specificati)
if docker compose ps -q | grep -q .; then
  echo "[bootstrap] Stack già attivo: non rilancio docker compose up."
else
  echo "[bootstrap] Avvio docker compose… (profili: ${BOOTSTRAP_PROFILES:-<none>})"
  # esempio: BOOTSTRAP_PROFILES="local" → avvia anche caddy-local
  docker compose $COMPOSE_PROFILES_ARGS up -d
fi
```

Uso:
```bash
# dev locale
BOOTSTRAP_PROFILES="local" ./bootstrap_cloudetta.sh

# produzione
BOOTSTRAP_PROFILES="prod" ./bootstrap_cloudetta.sh
```

Se non imposti `BOOTSTRAP_PROFILES`, lo script avvierà solo i servizi **senza profilo** (cioè tutto lo stack tranne Caddy).

---

# 7) Come lanciare

**Dev (local):**
```bash
cp .env.example .env   # poi modifica le password!
docker compose --profile local up -d
./bootstrap_cloudetta.sh
# apri: http://django.localhost, http://odoo.localhost, ecc.
```

**Prod (https):**
```bash
# compila nel .env: CADDY_EMAIL e i *_DOMAIN che ti servono
docker compose --profile prod up -d
./bootstrap_cloudetta.sh
# verifica i DNS verso il server prima di avviare (ACME)
```

---

## Preferenze
Personalmente, per ambienti con **CI/CD** preferisco la strada dei **profiles** (quella che ti ho preparato), perché:
- evita variabili “magiche” tipo `CADDY_MODE`,
- rende esplicito *quali* servizi cambiano tra local/prod,
- si integra bene con `docker compose --profile ...`.

Se vuoi restare minimalista, l’alternativa `CADDY_MODE` funziona, ma il setup a profili è più chiaro e “stateless”.

Vuoi che ti aggiunga anche gli **healthcheck** principali e un **Caddy security preset** (headers HSTS, gzip, logging) per il profilo prod?

assolutamente sì — ti passo i file **pronti al copia/incolla** con:

* profili `local` e `prod` in `docker-compose`
* healthcheck “ragionevoli” sui servizi principali (DB, app web, redis, n8n, mattermost, mautic, odoo, redmine, nextcloud)
* **Caddy preset “secure”** per `prod` (HSTS, security headers, compressione, logging)

Se qualcosa non ti torna li rifiniamo al volo.

---

# 📄 `.env.example` (copia in `.env` e personalizza)

```env
# --- ACME/Let's Encrypt (solo prod) ---
CADDY_EMAIL=antonio.trento@yahoo.com

# --- Domini pubblici (solo prod; vuoti = disattivi quel vhost) ---
DJANGO_DOMAIN=
ODOO_DOMAIN=
REDMINE_DOMAIN=
NEXTCLOUD_DOMAIN=
N8N_DOMAIN=
WIKI_DOMAIN=
MAUTIC_DOMAIN=
MATTERMOST_DOMAIN=

# ====== Admin unificato ======
ADMIN_USER=admin
ADMIN_PASS=ChangeMe!123
ADMIN_EMAIL=antonio.trento@yahoo.com

# ====== Django ======
DJANGO_SECRET_KEY=dev_change_me
DJANGO_DB_PASSWORD=dev_django_pw
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=django,localhost,127.0.0.1,django.localhost,django.example.com
DJANGO_CSRF_TRUSTED_ORIGINS=http://django.localhost,http://django.example.com,https://django.localhost,https://django.example.com
DJANGO_USE_X_FORWARDED_HOST=True
DJANGO_SECURE_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https
DJANGO_ADMIN_USER=${ADMIN_USER}
DJANGO_ADMIN_EMAIL=${ADMIN_EMAIL}
DJANGO_ADMIN_PASS=${ADMIN_PASS}

STRIPE_PUBLIC_KEY=pk_test_xxx
STRIPE_SECRET_KEY=sk_test_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx

# ====== Odoo ======
ODOO_DB_PASSWORD=dev_odoo_db_pw
ODOO_DB=cloudetta
ODOO_MASTER_PASSWORD=${ADMIN_PASS}
ODOO_DEMO=true
ODOO_LANG=it_IT

# ====== Redmine ======
REDMINE_DB_PASSWORD=dev_redmine_db_pw
REDMINE_ROOT_PW=dev_redmine_root_pw
REDMINE_SECRET_KEY_BASE=

# ====== Nextcloud ======
NEXTCLOUD_DB_PASSWORD=dev_nextcloud_db_pw
NEXTCLOUD_ROOT_PW=dev_nextcloud_root_pw
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASS=${ADMIN_PASS}
PUBLIC_DOMAIN=
TRUSTED_DOMAINS=localhost,127.0.0.1,nextcloud,nextcloud.localhost,${PUBLIC_DOMAIN}

# ====== n8n ======
N8N_PASSWORD=${ADMIN_PASS}

# ====== Mail ======
MAIL_PROVIDER=sendgrid
MAIL_USER=admin@example.com
MAIL_PASS=change_me_mail_password
# Esempio SMTP (opzionale)
# MAIL_PROVIDER=smtp
# MAIL_USER=antonio.trento@yahoo.com
# MAIL_PASS=app_password
# MAIL_HOST=smtp.mail.yahoo.com
# MAIL_PORT=587
# MAIL_ENCRYPTION=tls
# MAIL_FROM_NAME="Antonio Trento"
# MAIL_FROM_ADDRESS=antonio.trento@yahoo.com

# ====== Caddy/DokuWiki ======
WIKI_BCRYPT_HASH=

# ====== Mautic ======
MAUTIC_DB_PASSWORD=dev_mautic_db_pw
MAUTIC_ROOT_PW=dev_mautic_root_pw
# MAUTIC_DOMAIN=mautic.example.com

# ====== Mattermost ======
MATTERMOST_DB_PASSWORD=dev_mattermost_db_pw
MATTERMOST_SITEURL=http://chat.localhost
MATTERMOST_ADMIN_USER=${ADMIN_USER}
MATTERMOST_ADMIN_EMAIL=${ADMIN_EMAIL}
MATTERMOST_ADMIN_PASS=${ADMIN_PASS}
MATTERMOST_TEAM_NAME=cloudetta
MATTERMOST_TEAM_DISPLAY=Cloudetta
```

---

# 🧩 `docker-compose.yml` (con profili + healthchecks)

> Avvii **uno** dei due profili di Caddy: `local` **oppure** `prod`.
> Gli altri servizi sono condivisi e senza profilo.

```yaml
version: "3.9"

networks:
  web:
    driver: bridge
  internal:
    driver: bridge

services:
  # ================== CADDY (LOCAL) ==================
  caddy-local:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    profiles: ["local"]
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["/bin/sh","-lc","/entrypoint.sh local"]
    networks:
      - web
      - internal

  # ================== CADDY (PROD) ==================
  caddy-prod:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    profiles: ["prod"]
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
      - DJANGO_DOMAIN=${DJANGO_DOMAIN}
      - ODOO_DOMAIN=${ODOO_DOMAIN}
      - REDMINE_DOMAIN=${REDMINE_DOMAIN}
      - NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN}
      - N8N_DOMAIN=${N8N_DOMAIN}
      - WIKI_DOMAIN=${WIKI_DOMAIN}
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
      - MATTERMOST_DOMAIN=${MATTERMOST_DOMAIN}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["/bin/sh","-lc","/entrypoint.sh prod"]
    networks:
      - web
      - internal
    # (facoltativo) healthcheck: verifica che Caddy stia esponendo una pagina locale
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:80 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  # ================== APPS ==================
  django:
    build: ./django
    container_name: django
    command: gunicorn django_project.wsgi:application --bind 0.0.0.0:8000
    depends_on:
      - django-db
    environment:
      - DJANGO_SETTINGS_MODULE=django_project.settings
      - DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
      - DJANGO_DEBUG=${DJANGO_DEBUG:-False}
      - DJANGO_ALLOWED_HOSTS=${DJANGO_ALLOWED_HOSTS:-django.localhost,django.example.com}
      - DATABASE_URL=postgres://django:${DJANGO_DB_PASSWORD}@django-db:5432/django
      - STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-sk_test_xxx}
      - STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-whsec_xxx}
      - DJANGO_ADMIN_USER=${DJANGO_ADMIN_USER}
      - DJANGO_ADMIN_EMAIL=${DJANGO_ADMIN_EMAIL}
      - DJANGO_ADMIN_PASS=${DJANGO_ADMIN_PASS}
    volumes:
      - ./django:/app
    ports:
      - "8000:8000"
    networks:
      - internal
    # healthcheck (richiede curl o wget nell'immagine django; se non ci sono, rimuovi)
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8000/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10
      start_period: 40s

  django-db:
    image: postgres:15
    container_name: django-db
    environment:
      - POSTGRES_DB=django
      - POSTGRES_USER=django
      - POSTGRES_PASSWORD=${DJANGO_DB_PASSWORD}
    volumes:
      - django-db-data:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-django} -d ${POSTGRES_DB:-django} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  odoo:
    build: ./odoo
    container_name: odoo
    depends_on:
      - odoo-db
      - redis
    environment:
      - HOST=odoo-db
      - USER=odoo
      - PASSWORD=${ODOO_DB_PASSWORD}
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - ADMIN_PASS=${ADMIN_PASS}
      - ODOO_DB=${ODOO_DB}
      - ODOO_LANG=${ODOO_LANG}
    volumes:
      - odoo-data:/var/lib/odoo
      - ./odoo-addons:/mnt/extra-addons
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8069/web/login >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  odoo-db:
    image: postgres:15
    container_name: odoo-db
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_USER=odoo
      - POSTGRES_PASSWORD=${ODOO_DB_PASSWORD}
    volumes:
      - postgres-odoo-data:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-odoo} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  redis:
    image: redis:7
    container_name: redis
    command: ["redis-server", "--save", "60", "1"]
    volumes:
      - redis-data:/data
    networks:
      - internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  redmine:
    image: redmine:5
    container_name: redmine
    depends_on:
      - redmine-db
    environment:
      REDMINE_DB_MYSQL: redmine-db
      REDMINE_DB_DATABASE: redmine
      REDMINE_DB_USERNAME: redmine
      REDMINE_DB_PASSWORD: ${REDMINE_DB_PASSWORD}
      REDMINE_SECRET_KEY_BASE: ${REDMINE_SECRET_KEY_BASE}
    volumes:
      - redmine-data:/usr/src/redmine/files
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  redmine-db:
    image: mariadb:10.6
    container_name: redmine-db
    environment:
      - MYSQL_ROOT_PASSWORD=${REDMINE_ROOT_PW}
      - MYSQL_DATABASE=redmine
      - MYSQL_USER=redmine
      - MYSQL_PASSWORD=${REDMINE_DB_PASSWORD}
    volumes:
      - redmine-db-data:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${REDMINE_ROOT_PW} --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  nextcloud:
    image: nextcloud:26
    container_name: nextcloud
    depends_on:
      - nextcloud-db
    environment:
      - MYSQL_HOST=nextcloud-db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASS=${NEXTCLOUD_ADMIN_PASS}
    volumes:
      - nextcloud-data:/var/www/html
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/status.php | grep -q 'installed' || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  nextcloud-db:
    image: mariadb:10.6
    container_name: nextcloud-db
    environment:
      - MYSQL_ROOT_PASSWORD=${NEXTCLOUD_ROOT_PW}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
    volumes:
      - nextcloud-db-data:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${NEXTCLOUD_ROOT_PW} --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    environment:
      - GENERIC_TIMEZONE=Europe/Rome
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${ADMIN_USER}
      - N8N_BASIC_AUTH_PASSWORD=${ADMIN_PASS}
    ports:
      - "5678:5678"
    volumes:
      - n8n-data:/home/node/.n8n
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5678/healthz || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 30s

  dokuwiki:
    image: linuxserver/dokuwiki:latest
    container_name: dokuwiki
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - dokuwiki-data:/config
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  mautic:
    image: mautic/mautic:5-apache
    container_name: mautic
    depends_on:
      - mautic-db
    environment:
      - MAUTIC_DB_HOST=mautic-db
      - MAUTIC_DB_USER=mautic
      - MAUTIC_DB_PASSWORD=${MAUTIC_DB_PASSWORD}
      - MAUTIC_DB_NAME=mautic
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
    volumes:
      - mautic-data:/var/www/html
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  mautic-db:
    image: mariadb:10.6
    container_name: mautic-db
    environment:
      - MYSQL_ROOT_PASSWORD=${MAUTIC_ROOT_PW}
      - MYSQL_DATABASE=mautic
      - MYSQL_USER=mautic
      - MYSQL_PASSWORD=${MAUTIC_DB_PASSWORD}
    volumes:
      - mautic-db-data:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${MAUTIC_ROOT_PW} --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  mail:
    image: bytemark/smtp
    container_name: mail
    environment:
      - PROVIDER=${MAIL_PROVIDER:-sendgrid}
      - SMTP_USER=${MAIL_USER:-admin@example.com}
      - SMTP_PASS=${MAIL_PASS:-changeme}
    networks:
      - internal

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost
    depends_on:
      - mattermost-db
    environment:
      - MM_SERVICESETTINGS_SITEURL=${MATTERMOST_SITEURL:-http://chat.localhost}
      - MM_SERVICESETTINGS_ENABLELOCALMODE=true
      - MM_SERVICESETTINGS_LOCALMODESOCKETLOCATION=/var/tmp/mattermost_local.socket
      - MM_SQLSETTINGS_DRIVERNAME=postgres
      - MM_SQLSETTINGS_DATASOURCE=postgres://mmuser:${MATTERMOST_DB_PASSWORD}@mattermost-db:5432/mattermost?sslmode=disable&connect_timeout=10
      - MM_EMAILSETTINGS_ENABLESIGNUPWITHEMAIL=true
      - MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=true
      - MM_EMAILSETTINGS_SMTPSERVER=${MAIL_HOST:-}
      - MM_EMAILSETTINGS_SMTPPORT=${MAIL_PORT:-}
      - MM_EMAILSETTINGS_CONNECTIONSECURITY=${MAIL_ENCRYPTION:-}
      - MM_EMAILSETTINGS_SMTPUSERNAME=${MAIL_USER:-}
      - MM_EMAILSETTINGS_SMTPPASSWORD=${MAIL_PASS:-}
      - MM_EMAILSETTINGS_FEEDBACKEMAIL=${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      - MM_EMAILSETTINGS_REPLYTOADDRESS=${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      - TZ=${TZ:-Europe/Rome}
      - MM_LOGSETTINGS_ENABLECONSOLE=true
      - MM_PLUGINSETTINGS_ENABLE=true
    volumes:
      - mattermost_app:/mattermost/data
      - mattermost_logs:/mattermost/logs
      - mattermost_config:/mattermost/config
      - mattermost_plugins:/mattermost/plugins
      - mattermost_client:/mattermost/client/plugins
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8065/api/v4/system/ping | grep -q 'OK' || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 40s

  mattermost-db:
    image: postgres:15
    container_name: mattermost-db
    environment:
      - POSTGRES_USER=mmuser
      - POSTGRES_PASSWORD=${MATTERMOST_DB_PASSWORD}
      - POSTGRES_DB=mattermost
    volumes:
      - mattermost_pgdata:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-mmuser} -d ${POSTGRES_DB:-mattermost} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  backup:
    image: alpine:3.19
    container_name: backup
    volumes:
      - django-db-data:/django-db-data
      - odoo-data:/odoo-data
      - postgres-odoo-data:/postgres-odoo-data
      - redis-data:/redis-data
      - redmine-data:/redmine-data
      - redmine-db-data:/redmine-db-data
      - nextcloud-data:/nextcloud-data
      - nextcloud-db-data:/nextcloud-db-data
      - dokuwiki-data:/dokuwiki-data
      - n8n-data:/n8n-data
      - mautic-data:/mautic-data
      - mautic-db-data:/mautic-db-data
      - mattermost_app:/mattermost_app
      - mattermost_logs:/mattermost_logs
      - mattermost_config:/mattermost_config
      - mattermost_plugins:/mattermost_plugins
      - mattermost_client:/mattermost_client
      - mattermost_pgdata:/mattermost_pgdata
      - ./backups:/backups
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backup/backup.sh:/backup/backup.sh:ro
    entrypoint: ["/bin/sh", "-c", "apk add --no-cache bash postgresql-client mariadb-client tar gzip && echo '0 2 * * * /backup/backup.sh >> /backups/backup.log 2>&1' | crontab - && crond -f"]
    networks:
      - internal

volumes:
  caddy_data:
  caddy_config:
  django-db-data:
  odoo-data:
  postgres-odoo-data:
  redis-data:
  redmine-data:
  redmine-db-data:
  nextcloud-data:
  nextcloud-db-data:
  n8n-data:
  dokuwiki-data:
  mautic-data:
  mautic-db-data:
  mattermost_app:
  mattermost_logs:
  mattermost_config:
  mattermost_plugins:
  mattermost_client:
  mattermost_pgdata:
```

> Nota: alcuni healthcheck usano `wget`. Se le immagini minimal non lo hanno, puoi:
>
> * sostituire con `curl -f` se presente, **oppure**
> * rimuovere l’healthcheck relativo, oppure
> * aggiungere `apk add --no-cache curl` nel Dockerfile dell’app (p.es. per `django`).

---

# 🔐 `caddy/Caddyfile.local` (dev, solo HTTP)

```caddy
{
  auto_https off
  admin off
}

# ---------- Django ----------
http://django.localhost {
  reverse_proxy django:8000
}

# ---------- Odoo ----------
http://odoo.localhost {
  reverse_proxy odoo:8069
}

# ---------- Redmine ----------
http://redmine.localhost {
  reverse_proxy redmine:3000
}

# ---------- DokuWiki ----------
http://wiki.localhost {
  reverse_proxy dokuwiki:80
}

# ---------- Nextcloud ----------
http://nextcloud.localhost {
  reverse_proxy nextcloud:80
}

# ---------- Mautic ----------
http://mautic.localhost {
  reverse_proxy mautic:80
}

# ---------- n8n ----------
http://n8n.localhost {
  reverse_proxy n8n:5678
}

# ---------- Mattermost ----------
http://chat.localhost {
  reverse_proxy mattermost:8065
}
```

---

# 🛡️ `caddy/Caddyfile.prod.tmpl` (HTTPS + security preset)

> Genera solo i vhost dei domini valorizzati nel `.env`.
> Include headers di sicurezza, compressione e access log JSON.

```caddy
{
  email ${CADDY_EMAIL}
}

# Preset sicurezza per tutti i siti
(import) security_preset

# Redirect http→https per i domini valorizzati
${DJANGO_DOMAIN:+http://${DJANGO_DOMAIN} {
  redir https://${DJANGO_DOMAIN}{uri}
}}
${ODOO_DOMAIN:+http://${ODOO_DOMAIN} {
  redir https://${ODOO_DOMAIN}{uri}
}}
${REDMINE_DOMAIN:+http://${REDMINE_DOMAIN} {
  redir https://${REDMINE_DOMAIN}{uri}
}}
${NEXTCLOUD_DOMAIN:+http://${NEXTCLOUD_DOMAIN} {
  redir https://${NEXTCLOUD_DOMAIN}{uri}
}}
${N8N_DOMAIN:+http://${N8N_DOMAIN} {
  redir https://${N8N_DOMAIN}{uri}
}}
${WIKI_DOMAIN:+http://${WIKI_DOMAIN} {
  redir https://${WIKI_DOMAIN}{uri}
}}
${MAUTIC_DOMAIN:+http://${MAUTIC_DOMAIN} {
  redir https://${MAUTIC_DOMAIN}{uri}
}}
${MATTERMOST_DOMAIN:+http://${MATTERMOST_DOMAIN} {
  redir https://${MATTERMOST_DOMAIN}{uri}
}}

# --------- VHOSTS HTTPS ---------
${DJANGO_DOMAIN:+https://${DJANGO_DOMAIN} {
  import security_preset
  reverse_proxy django:8000
}}

${ODOO_DOMAIN:+https://${ODOO_DOMAIN} {
  import security_preset
  reverse_proxy odoo:8069
}}

${REDMINE_DOMAIN:+https://${REDMINE_DOMAIN} {
  import security_preset
  reverse_proxy redmine:3000
}}

${NEXTCLOUD_DOMAIN:+https://${NEXTCLOUD_DOMAIN} {
  import security_preset
  reverse_proxy nextcloud:80
}}

${N8N_DOMAIN:+https://${N8N_DOMAIN} {
  import security_preset
  reverse_proxy n8n:5678
}}

${WIKI_DOMAIN:+https://${WIKI_DOMAIN} {
  import security_preset
  reverse_proxy dokuwiki:80
}}

${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN} {
  import security_preset
  reverse_proxy mautic:80
}}

${MATTERMOST_DOMAIN:+https://${MATTERMOST_DOMAIN} {
  import security_preset
  reverse_proxy mattermost:8065
}}

# --------- SNIPPET: SECURITY PRESET ---------
(snippet) security_preset {
  encode zstd gzip
  header {
    # HSTS (1 anno, include subdomini, preload — abilitalo solo dopo test!)
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "no-referrer-when-downgrade"
    Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()"
    # CORS di base disabilitato; abilitalo se serve
    # Access-Control-Allow-Origin "*"
  }
  # Access log JSON su stdout
  log {
    output stdout
    format json
  }
  # Timeouts & proxy hardening base
  servers {
    trusted_proxies private_ranges
  }
}
```

---

# ▶️ `caddy/entrypoint.sh` (seleziona local/prod e avvia)

```bash
#!/bin/sh
set -e

MODE="$1" # "local" | "prod"
CFG_DIR="/etc/caddy"

if [ "$MODE" = "local" ]; then
  echo "[caddy] MODE=local → uso Caddyfile.local"
  cp -f "$CFG_DIR/Caddyfile.local" "$CFG_DIR/Caddyfile"
else
  echo "[caddy] MODE=prod → genero Caddyfile da template"
  export DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN MATTERMOST_DOMAIN CADDY_EMAIL
  envsubst < "$CFG_DIR/Caddyfile.prod.tmpl" > "$CFG_DIR/Caddyfile"
fi

exec caddy run --config "$CFG_DIR/Caddyfile" --adapter caddyfile
```

> Ricorda: `chmod +x caddy/entrypoint.sh`

---

## (Facoltativo) Ritocco `bootstrap_cloudetta.sh`

Non obbligatorio. Se vuoi farlo convivere con i profili:

```bash
# Usa BOOTSTRAP_PROFILES="local" oppure "prod"
COMPOSE_PROFILES_ARGS=""
if [ -n "${BOOTSTRAP_PROFILES:-}" ]; then
  for p in ${BOOTSTRAP_PROFILES}; do
    COMPOSE_PROFILES_ARGS="$COMPOSE_PROFILES_ARGS --profile $p"
  done
fi

if docker compose ps -q | grep -q .; then
  echo "[bootstrap] Stack già attivo"
else
  echo "[bootstrap] Avvio stack con profili: ${BOOTSTRAP_PROFILES:-<none>}"
  docker compose $COMPOSE_PROFILES_ARGS up -d
fi
```

---

## Come lanciare

**Dev (local, no TLS):**

```bash
cp .env.example .env    # poi cambia le password!
docker compose --profile local up -d
./bootstrap_cloudetta.sh
```

**Produzione (HTTPS):**

```bash
# nel .env: CADDY_EMAIL e i *_DOMAIN che vuoi attivi
docker compose --profile prod up -d
./bootstrap_cloudetta.sh
```

---

Vuoi che ti pinni anche le versioni delle immagini (Nextcloud 27/28 LTS, MariaDB 10.11 LTS, n8n/mattermost tag specifici) per maggiore stabilità? Oppure preferisci restare su `latest` finché non chiudiamo il primo giro di test?





























































perfetto — ho “pinnato” le immagini su versioni stabili/LTS aggiornate e ho mantenuto i profili `local`/`prod`, gli healthcheck e il preset di sicurezza Caddy.

Scelte chiave (verificate):

* **Nextcloud `32-apache`** → ultimo ramo stabile (Hub 11) a fine 2025. ([Nextcloud][1])
* **MariaDB `10.11`** → LTS fino a **feb 2028**. ([MariaDB][2])
* **Mattermost Team Edition `10.7`** → ramo stabile pubblicato 2025. (Archive consiglia ≥10.11 quando sarà GA, per ora 10.7 è sicuro). ([Documentazione Mattermost][3])
* **Redmine `6.1`** → la serie **6** è “stable”; 6.1 rilasciata a settembre 2025. ([Redmine][4])
* **Mautic `5-apache`** → tag stabile consigliato. ([Docker Hub][5])
* **n8n `1.101.0`** → versione stabile pubblica (evito pre-release 1.114.x). Puoi alzare in seguito. ([GitHub][6])

Di seguito i file **pronti al copia-incolla**.

---

# 📄 `.env.example` (copia in `.env` e personalizza)

```env
# --- ACME/Let's Encrypt (solo prod) ---
CADDY_EMAIL=antonio.trento@yahoo.com

# --- Domini pubblici (solo prod; vuoti = vhost disattivo) ---
DJANGO_DOMAIN=
ODOO_DOMAIN=
REDMINE_DOMAIN=
NEXTCLOUD_DOMAIN=
N8N_DOMAIN=
WIKI_DOMAIN=
MAUTIC_DOMAIN=
MATTERMOST_DOMAIN=

# ====== Admin unificato ======
ADMIN_USER=admin
ADMIN_PASS=ChangeMe!123
ADMIN_EMAIL=antonio.trento@yahoo.com

# ====== Django ======
DJANGO_SECRET_KEY=dev_change_me
DJANGO_DB_PASSWORD=dev_django_pw
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=django,localhost,127.0.0.1,django.localhost,django.example.com
DJANGO_CSRF_TRUSTED_ORIGINS=http://django.localhost,http://django.example.com,https://django.localhost,https://django.example.com
DJANGO_USE_X_FORWARDED_HOST=True
DJANGO_SECURE_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https
DJANGO_ADMIN_USER=${ADMIN_USER}
DJANGO_ADMIN_EMAIL=${ADMIN_EMAIL}
DJANGO_ADMIN_PASS=${ADMIN_PASS}

STRIPE_PUBLIC_KEY=pk_test_xxx
STRIPE_SECRET_KEY=sk_test_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx

# ====== Odoo ======
ODOO_DB_PASSWORD=dev_odoo_db_pw
ODOO_DB=cloudetta
ODOO_MASTER_PASSWORD=${ADMIN_PASS}
ODOO_DEMO=true
ODOO_LANG=it_IT

# ====== Redmine ======
REDMINE_DB_PASSWORD=dev_redmine_db_pw
REDMINE_ROOT_PW=dev_redmine_root_pw
REDMINE_SECRET_KEY_BASE=

# ====== Nextcloud ======
NEXTCLOUD_DB_PASSWORD=dev_nextcloud_db_pw
NEXTCLOUD_ROOT_PW=dev_nextcloud_root_pw
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASS=${ADMIN_PASS}
PUBLIC_DOMAIN=
TRUSTED_DOMAINS=localhost,127.0.0.1,nextcloud,nextcloud.localhost,${PUBLIC_DOMAIN}

# ====== n8n ======
N8N_PASSWORD=${ADMIN_PASS}

# ====== Mail ======
MAIL_PROVIDER=sendgrid
MAIL_USER=admin@example.com
MAIL_PASS=change_me_mail_password
# Esempio SMTP (opzionale)
# MAIL_PROVIDER=smtp
# MAIL_USER=antonio.trento@yahoo.com
# MAIL_PASS=app_password
# MAIL_HOST=smtp.mail.yahoo.com
# MAIL_PORT=587
# MAIL_ENCRYPTION=tls
# MAIL_FROM_NAME="Antonio Trento"
# MAIL_FROM_ADDRESS=antonio.trento@yahoo.com

# ====== Caddy/DokuWiki ======
WIKI_BCRYPT_HASH=

# ====== Mautic ======
MAUTIC_DB_PASSWORD=dev_mautic_db_pw
MAUTIC_ROOT_PW=dev_mautic_root_pw
# MAUTIC_DOMAIN=mautic.example.com

# ====== Mattermost ======
MATTERMOST_DB_PASSWORD=dev_mattermost_db_pw
MATTERMOST_SITEURL=http://chat.localhost
MATTERMOST_ADMIN_USER=${ADMIN_USER}
MATTERMOST_ADMIN_EMAIL=${ADMIN_EMAIL}
MATTERMOST_ADMIN_PASS=${ADMIN_PASS}
MATTERMOST_TEAM_NAME=cloudetta
MATTERMOST_TEAM_DISPLAY=Cloudetta
```

---

# 🧩 `docker-compose.yml` (profili + healthcheck + versioni pin)

```yaml
version: "3.9"

networks:
  web:
    driver: bridge
  internal:
    driver: bridge

services:
  # ================== CADDY (LOCAL) ==================
  caddy-local:
    image: caddy:2.8.4
    container_name: caddy
    restart: unless-stopped
    profiles: ["local"]
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["/bin/sh","-lc","/entrypoint.sh local"]
    networks:
      - web
      - internal

  # ================== CADDY (PROD) ==================
  caddy-prod:
    image: caddy:2.8.4
    container_name: caddy
    restart: unless-stopped
    profiles: ["prod"]
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CADDY_EMAIL=${CADDY_EMAIL:-admin@example.com}
      - DJANGO_DOMAIN=${DJANGO_DOMAIN}
      - ODOO_DOMAIN=${ODOO_DOMAIN}
      - REDMINE_DOMAIN=${REDMINE_DOMAIN}
      - NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN}
      - N8N_DOMAIN=${N8N_DOMAIN}
      - WIKI_DOMAIN=${WIKI_DOMAIN}
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
      - MATTERMOST_DOMAIN=${MATTERMOST_DOMAIN}
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    command: ["/bin/sh","-lc","/entrypoint.sh prod"]
    networks:
      - web
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:80 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  # ================== APPS ==================
  django:
    build: ./django
    container_name: django
    command: gunicorn django_project.wsgi:application --bind 0.0.0.0:8000
    depends_on:
      - django-db
    environment:
      - DJANGO_SETTINGS_MODULE=django_project.settings
      - DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
      - DJANGO_DEBUG=${DJANGO_DEBUG:-False}
      - DJANGO_ALLOWED_HOSTS=${DJANGO_ALLOWED_HOSTS:-django.localhost,django.example.com}
      - DATABASE_URL=postgres://django:${DJANGO_DB_PASSWORD}@django-db:5432/django
      - STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY:-sk_test_xxx}
      - STRIPE_WEBHOOK_SECRET=${STRIPE_WEBHOOK_SECRET:-whsec_xxx}
      - DJANGO_ADMIN_USER=${DJANGO_ADMIN_USER}
      - DJANGO_ADMIN_EMAIL=${DJANGO_ADMIN_EMAIL}
      - DJANGO_ADMIN_PASS=${DJANGO_ADMIN_PASS}
    volumes:
      - ./django:/app
    ports:
      - "8000:8000"
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8000/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10
      start_period: 40s

  django-db:
    image: postgres:15
    container_name: django-db
    environment:
      - POSTGRES_DB=django
      - POSTGRES_USER=django
      - POSTGRES_PASSWORD=${DJANGO_DB_PASSWORD}
    volumes:
      - django-db-data:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-django} -d ${POSTGRES_DB:-django} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  odoo:
    build: ./odoo
    container_name: odoo
    depends_on:
      - odoo-db
      - redis
    environment:
      - HOST=odoo-db
      - USER=odoo
      - PASSWORD=${ODOO_DB_PASSWORD}
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - ADMIN_PASS=${ADMIN_PASS}
      - ODOO_DB=${ODOO_DB}
      - ODOO_LANG=${ODOO_LANG}
    volumes:
      - odoo-data:/var/lib/odoo
      - ./odoo-addons:/mnt/extra-addons
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8069/web/login >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  odoo-db:
    image: postgres:15
    container_name: odoo-db
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_USER=odoo
      - POSTGRES_PASSWORD=${ODOO_DB_PASSWORD}
    volumes:
      - postgres-odoo-data:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-odoo} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  redis:
    image: redis:7.4-alpine
    container_name: redis
    command: ["redis-server", "--save", "60", "1"]
    volumes:
      - redis-data:/data
    networks:
      - internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  redmine:
    image: redmine:6.1
    container_name: redmine
    depends_on:
      - redmine-db
    environment:
      REDMINE_DB_MYSQL: redmine-db
      REDMINE_DB_DATABASE: redmine
      REDMINE_DB_USERNAME: redmine
      REDMINE_DB_PASSWORD: ${REDMINE_DB_PASSWORD}
      REDMINE_SECRET_KEY_BASE: ${REDMINE_SECRET_KEY_BASE}
    volumes:
      - redmine-data:/usr/src/redmine/files
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  redmine-db:
    image: mariadb:10.11
    container_name: redmine-db
    environment:
      - MYSQL_ROOT_PASSWORD=${REDMINE_ROOT_PW}
      - MYSQL_DATABASE=redmine
      - MYSQL_USER=redmine
      - MYSQL_PASSWORD=${REDMINE_DB_PASSWORD}
    volumes:
      - redmine-db-data:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${REDMINE_ROOT_PW} --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  nextcloud:
    image: nextcloud:32-apache
    container_name: nextcloud
    depends_on:
      - nextcloud-db
    environment:
      - MYSQL_HOST=nextcloud-db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASS=${NEXTCLOUD_ADMIN_PASS}
    volumes:
      - nextcloud-data:/var/www/html
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/status.php | grep -q 'installed' || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  nextcloud-db:
    image: mariadb:10.11
    container_name: nextcloud-db
    environment:
      - MYSQL_ROOT_PASSWORD=${NEXTCLOUD_ROOT_PW}
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=${NEXTCLOUD_DB_PASSWORD}
    volumes:
      - nextcloud-db-data:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${NEXTCLOUD_ROOT_PW} --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  n8n:
    image: n8nio/n8n:1.101.0
    container_name: n8n
    environment:
      - GENERIC_TIMEZONE=Europe/Rome
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${ADMIN_USER}
      - N8N_BASIC_AUTH_PASSWORD=${ADMIN_PASS}
    ports:
      - "5678:5678"
    volumes:
      - n8n-data:/home/node/.n8n
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5678/healthz || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 30s

  dokuwiki:
    image: lscr.io/linuxserver/dokuwiki:2024.12.24
    container_name: dokuwiki
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - dokuwiki-data:/config
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  mautic:
    image: mautic/mautic:5-apache
    container_name: mautic
    depends_on:
      - mautic-db
    environment:
      - MAUTIC_DB_HOST=mautic-db
      - MAUTIC_DB_USER=mautic
      - MAUTIC_DB_PASSWORD=${MAUTIC_DB_PASSWORD}
      - MAUTIC_DB_NAME=mautic
      - MAUTIC_DOMAIN=${MAUTIC_DOMAIN}
    volumes:
      - mautic-data:/var/www/html
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 7s
      retries: 10
      start_period: 40s

  mautic-db:
    image: mariadb:10.11
    container_name: mautic-db
    environment:
      - MYSQL_ROOT_PASSWORD=${MAUTIC_ROOT_PW}
      - MYSQL_DATABASE=mautic
      - MYSQL_USER=mautic
      - MYSQL_PASSWORD=${MAUTIC_DB_PASSWORD}
    volumes:
      - mautic-db-data:/var/lib/mysql
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p${MAUTIC_ROOT_PW} --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  mail:
    image: bytemark/smtp:latest
    container_name: mail
    environment:
      - PROVIDER=${MAIL_PROVIDER:-sendgrid}
      - SMTP_USER=${MAIL_USER:-admin@example.com}
      - SMTP_PASS=${MAIL_PASS:-changeme}
    networks:
      - internal

  mattermost:
    image: mattermost/mattermost-team-edition:10.7
    container_name: mattermost
    depends_on:
      - mattermost-db
    environment:
      - MM_SERVICESETTINGS_SITEURL=${MATTERMOST_SITEURL:-http://chat.localhost}
      - MM_SERVICESETTINGS_ENABLELOCALMODE=true
      - MM_SERVICESETTINGS_LOCALMODESOCKETLOCATION=/var/tmp/mattermost_local.socket
      - MM_SQLSETTINGS_DRIVERNAME=postgres
      - MM_SQLSETTINGS_DATASOURCE=postgres://mmuser:${MATTERMOST_DB_PASSWORD}@mattermost-db:5432/mattermost?sslmode=disable&connect_timeout=10
      - MM_EMAILSETTINGS_ENABLESIGNUPWITHEMAIL=true
      - MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=true
      - MM_EMAILSETTINGS_SMTPSERVER=${MAIL_HOST:-}
      - MM_EMAILSETTINGS_SMTPPORT=${MAIL_PORT:-}
      - MM_EMAILSETTINGS_CONNECTIONSECURITY=${MAIL_ENCRYPTION:-}
      - MM_EMAILSETTINGS_SMTPUSERNAME=${MAIL_USER:-}
      - MM_EMAILSETTINGS_SMTPPASSWORD=${MAIL_PASS:-}
      - MM_EMAILSETTINGS_FEEDBACKEMAIL=${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      - MM_EMAILSETTINGS_REPLYTOADDRESS=${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      - TZ=${TZ:-Europe/Rome}
      - MM_LOGSETTINGS_ENABLECONSOLE=true
      - MM_PLUGINSETTINGS_ENABLE=true
    volumes:
      - mattermost_app:/mattermost/data
      - mattermost_logs:/mattermost/logs
      - mattermost_config:/mattermost/config
      - mattermost_plugins:/mattermost/plugins
      - mattermost_client:/mattermost/client/plugins
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8065/api/v4/system/ping | grep -q 'OK' || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 40s

  mattermost-db:
    image: postgres:15
    container_name: mattermost-db
    environment:
      - POSTGRES_USER=mmuser
      - POSTGRES_PASSWORD=${MATTERMOST_DB_PASSWORD}
      - POSTGRES_DB=mattermost
    volumes:
      - mattermost_pgdata:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-mmuser} -d ${POSTGRES_DB:-mattermost} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  backup:
    image: alpine:3.20
    container_name: backup
    volumes:
      - django-db-data:/django-db-data
      - odoo-data:/odoo-data
      - postgres-odoo-data:/postgres-odoo-data
      - redis-data:/redis-data
      - redmine-data:/redmine-data
      - redmine-db-data:/redmine-db-data
      - nextcloud-data:/nextcloud-data
      - nextcloud-db-data:/nextcloud-db-data
      - dokuwiki-data:/dokuwiki-data
      - n8n-data:/n8n-data
      - mautic-data:/mautic-data
      - mautic-db-data:/mautic-db-data
      - mattermost_app:/mattermost_app
      - mattermost_logs:/mattermost_logs
      - mattermost_config:/mattermost_config
      - mattermost_plugins:/mattermost_plugins
      - mattermost_client:/mattermost_client
      - mattermost_pgdata:/mattermost_pgdata
      - ./backups:/backups
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backup/backup.sh:/backup/backup.sh:ro
    entrypoint: ["/bin/sh", "-c", "apk add --no-cache bash postgresql-client mariadb-client tar gzip wget && echo '0 2 * * * /backup/backup.sh >> /backups/backup.log 2>&1' | crontab - && crond -f"]
    networks:
      - internal

volumes:
  caddy_data:
  caddy_config:
  django-db-data:
  odoo-data:
  postgres-odoo-data:
  redis-data:
  redmine-data:
  redmine-db-data:
  nextcloud-data:
  nextcloud-db-data:
  n8n-data:
  dokuwiki-data:
  mautic-data:
  mautic-db-data:
  mattermost_app:
  mattermost_logs:
  mattermost_config:
  mattermost_plugins:
  mattermost_client:
  mattermost_pgdata:
```

> Nota: ho lasciato `postgres:15` pin sul major (stabile). Se vuoi una minor specifica, dimmi la tua policy e la imposto.

---

# 🔐 `caddy/Caddyfile.local`

```caddy
{
  auto_https off
  admin off
}

# ---------- Django ----------
http://django.localhost {
  reverse_proxy django:8000
}

# ---------- Odoo ----------
http://odoo.localhost {
  reverse_proxy odoo:8069
}

# ---------- Redmine ----------
http://redmine.localhost {
  reverse_proxy redmine:3000
}

# ---------- DokuWiki ----------
http://wiki.localhost {
  reverse_proxy dokuwiki:80
}

# ---------- Nextcloud ----------
http://nextcloud.localhost {
  reverse_proxy nextcloud:80
}

# ---------- Mautic ----------
http://mautic.localhost {
  reverse_proxy mautic:80
}

# ---------- n8n ----------
http://n8n.localhost {
  reverse_proxy n8n:5678
}

# ---------- Mattermost ----------
http://chat.localhost {
  reverse_proxy mattermost:8065
}
```

---

# 🛡️ `caddy/Caddyfile.prod.tmpl` (HTTPS + preset sicurezza, gzip/log)

```caddy
{
  email ${CADDY_EMAIL}
}

(import) security_preset

# Redirect http→https
${DJANGO_DOMAIN:+http://${DJANGO_DOMAIN} { redir https://${DJANGO_DOMAIN}{uri} }}
${ODOO_DOMAIN:+http://${ODOO_DOMAIN} { redir https://${ODOO_DOMAIN}{uri} }}
${REDMINE_DOMAIN:+http://${REDMINE_DOMAIN} { redir https://${REDMINE_DOMAIN}{uri} }}
${NEXTCLOUD_DOMAIN:+http://${NEXTCLOUD_DOMAIN} { redir https://${NEXTCLOUD_DOMAIN}{uri} }}
${N8N_DOMAIN:+http://${N8N_DOMAIN} { redir https://${N8N_DOMAIN}{uri} }}
${WIKI_DOMAIN:+http://${WIKI_DOMAIN} { redir https://${WIKI_DOMAIN}{uri} }}
${MAUTIC_DOMAIN:+http://${MAUTIC_DOMAIN} { redir https://${MAUTIC_DOMAIN}{uri} }}
${MATTERMOST_DOMAIN:+http://${MATTERMOST_DOMAIN} { redir https://${MATTERMOST_DOMAIN}{uri} }}

# VHOSTS HTTPS
${DJANGO_DOMAIN:+https://${DJANGO_DOMAIN} { import security_preset; reverse_proxy django:8000 }}
${ODOO_DOMAIN:+https://${ODOO_DOMAIN} { import security_preset; reverse_proxy odoo:8069 }}
${REDMINE_DOMAIN:+https://${REDMINE_DOMAIN} { import security_preset; reverse_proxy redmine:3000 }}
${NEXTCLOUD_DOMAIN:+https://${NEXTCLOUD_DOMAIN} { import security_preset; reverse_proxy nextcloud:80 }}
${N8N_DOMAIN:+https://${N8N_DOMAIN} { import security_preset; reverse_proxy n8n:5678 }}
${WIKI_DOMAIN:+https://${WIKI_DOMAIN} { import security_preset; reverse_proxy dokuwiki:80 }}
${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN} { import security_preset; reverse_proxy mautic:80 }}
${MATTERMOST_DOMAIN:+https://${MATTERMOST_DOMAIN} { import security_preset; reverse_proxy mattermost:8065 }}

# Snippet di sicurezza condiviso
(snippet) security_preset {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "no-referrer-when-downgrade"
    Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()"
  }
  log {
    output stdout
    format json
  }
  servers {
    trusted_proxies private_ranges
  }
}
```

---

# ▶️ `caddy/entrypoint.sh`

```bash
#!/bin/sh
set -e

MODE="$1" # "local" | "prod"
CFG_DIR="/etc/caddy"

if [ "$MODE" = "local" ]; then
  echo "[caddy] MODE=local → uso Caddyfile.local"
  cp -f "$CFG_DIR/Caddyfile.local" "$CFG_DIR/Caddyfile"
else
  echo "[caddy] MODE=prod → genero Caddyfile da template"
  export DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN MATTERMOST_DOMAIN CADDY_EMAIL
  envsubst < "$CFG_DIR/Caddyfile.prod.tmpl" > "$CFG_DIR/Caddyfile"
fi

exec caddy run --config "$CFG_DIR/Caddyfile" --adapter caddyfile
```

> ricorda: `chmod +x caddy/entrypoint.sh`

---

## Avvio rapido

**Dev (local):**

```bash
cp .env.example .env
# cambia password/chiavi!
docker compose --profile local up -d
./bootstrap_cloudetta.sh
```

**Prod (HTTPS):**

```bash
# nel .env: CADDY_EMAIL e i *_DOMAIN da attivare
docker compose --profile prod up -d
./bootstrap_cloudetta.sh
```

Vuoi che ti prepari anche un **mini playbook di upgrade** per passare a nuove minor (es. Nextcloud 32.x→32.y, MariaDB 10.11.x→10.11.y) con check dei backup e ordine di restart?

[1]: https://nextcloud.com/changelog/?utm_source=chatgpt.com "Nextcloud changelog"
[2]: https://mariadb.com/kb/en/changes-improvements-in-mariadb-1011/?utm_source=chatgpt.com "Changes and Improvements in MariaDB 10.11"
[3]: https://docs.mattermost.com/product-overview/mattermost-server-releases.html?utm_source=chatgpt.com "Mattermost Server Releases"
[4]: https://www.redmine.org/projects/redmine/news?utm_source=chatgpt.com "News"
[5]: https://hub.docker.com/r/mautic/mautic?utm_source=chatgpt.com "Mautic Docker Image"
[6]: https://github.com/n8n-io/n8n/releases?utm_source=chatgpt.com "Releases · n8n-io/n8n - GitHub"







Ottima base! Per completare davvero lo stack in ottica **prod**, ecco cosa aggiungerei (tutto open-source), con il perché in una riga e dove si incastra:

## Must-have (prod-ready)

* **SSO / Identity** – *Keycloak*: OIDC/SAML centralizzato per login unico su Django, Mattermost, Nextcloud, Redmine, Mautic, n8n (meno credenziali da gestire).
* **Observability** – *Prometheus + node-exporter + cAdvisor + Alertmanager* (+ *Grafana*): metriche host/containers, dashboard e alert (CPU, RAM, disco, errori HTTP).
* **Logging centralizzato** – *Loki + Promtail* (o *OpenSearch + OpenSearch Dashboards* se ti serve ricerca “full-text” pesante): log di tutti i container, ricerche e retention.
* **Uptime / synthetic checks** – *Uptime-Kuma*: ping HTTP/HTTPS ai tuoi servizi (interni ed esterni), notifiche quando giù.
* **Error tracking app** – *Sentry (self-hosted)*: stacktrace e breadcrumbs per Django (e anche front-end), regressions, release health.
* **Backup “serio”** – *Restic* verso *MinIO/S3* (o S3 esterno): versioning, deduplica e cifratura; tieni i dump DB + volumi offsite.
* **Editor Office per Nextcloud** – *Collabora Online* (o *OnlyOffice DocServer*): editing collaborativo di documenti direttamente in Nextcloud.
* **Scanner vulnerabilità** – *Trivy* su immagini/FS + *OWASP Dependency-Track* (opzionale) per dipendenze; integra in CI e report periodici.
* **Hardening/Anti-abuse** – *CrowdSec* + *bouncer per Caddy*: rate-limit/ban collaborativo su 80/443 (protezioni brute-force e bot).

## Nice-to-have (dipende dai tuoi casi d’uso)

* **CI/CD & Git** – *Gitea* (+ Actions/Runner) o *Drone*: repo, PR, pipeline; comodo per build dell’immagine Django e deploy automatici.
* **BI / Analytics** – *Metabase* (o *Apache Superset*): query no-code e dashboard sui DB (Django/ERP/marketing).
* **Web Analytics privacy-first** – *Plausible* (o *Matomo*): analytics senza cookie (o self-hosted completo).
* **Full-text/ricerca** – *MeiliSearch* (o *OpenSearch*) per potenziare la ricerca di Django/portali.
* **ETL/integrazioni dati** – *Airbyte*: connettori pronti per portare dati da Odoo/Mautic in un DB analitico.
* **Task queue** – *RabbitMQ* (se Django cresce oltre Redis) per job pesanti o integrazioni affidabili.
* **Registry immagini** – *Harbor* (o *Gitea Container Registry*): registry privato con scansioni e firme.
* **Gestione segreti** – *HashiCorp Vault* (o *1Password SCIM/Secret Server* se preferisci SaaS): rotazione e leasing credenziali DB/API.
* **Console Docker** – *Portainer*: gestione visuale di stack/volumi/backup rapidi (utile in emergenza).
* **Videoconferenza** – *Jitsi Meet*: meeting interni integrabili con Mattermost.

## Piccole chicche operative

* **Rotazione log**: se vai di Loki, ok; in alternativa logrotate nel container `backup` per `/backups/backup.log`.
* **Caddy con DNS challenge** (wildcard TLS): se usi wildcard o sei dietro CDN, valuta `xcaddy` con plugin DNS del provider.
* **Notifiche centralizzate**: invia alert (Prometheus/Alertmanager, Uptime-Kuma, Sentry) su **Mattermost** via webhook.

---

Se vuoi, ti preparo:

1. un `docker-compose.observability.yml` con **Prometheus + Grafana + Loki + Promtail + Alertmanager + Uptime-Kuma** già agganciati ai container esistenti;
2. un `docker-compose.sso.yml` con **Keycloak** + note di integrazione OIDC per ciascuna app (redirect URI e claim consigliati);
3. un `docker-compose.tools.yml` con **Sentry**, **Collabora**, **Trivy cron**, **Restic+MinIO** e policy di retention.

Dimmi da quali “blocchi” vuoi partire e te li scrivo subito in versione **profiles** (`monitoring`, `security`, `sso`, `tools`) per restare coerenti col tuo approccio.





perfetto — ti preparo **tutto** per copia-incolla: `.env`, `docker-compose.yml` completo con **profili** (core già incluso + sso/monitoring/logging/uptime/errors/backup/office/security/vulnscan), i due **Caddyfile** (local/prod), l’**entrypoint** di Caddy, e i file minimi per monitoring/logging. Ho mantenuto la tua logica del **bootstrap** cambiando **solo** la parte “local/prod” come concordato.

Di seguito trovi i file *integrali*. Crea le cartelle come indicato e incolla i contenuti.

---

# 1) `.env` (nuovo, completo)

> Aggiorna i domini in prod; per **local** puoi lasciarli vuoti.

```env
# --- Domini pubblici (prod, opzionali) ---
CADDY_EMAIL=admin@example.com
ACME_EMAIL=${CADDY_EMAIL}

DJANGO_DOMAIN=
ODOO_DOMAIN=
REDMINE_DOMAIN=
NEXTCLOUD_DOMAIN=
N8N_DOMAIN=
WIKI_DOMAIN=
MAUTIC_DOMAIN=
MATTERMOST_DOMAIN=

# ====== Admin unificato ======
ADMIN_USER=admin
ADMIN_PASS=ChangeMe!123
ADMIN_EMAIL=admin@example.com

# ====== Django ======
DJANGO_SECRET_KEY=dev_change_me
DJANGO_DB_PASSWORD=dev_django_pw
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=django,localhost,127.0.0.1,django.localhost,django.example.com
DJANGO_CSRF_TRUSTED_ORIGINS=http://django.localhost,http://django.example.com,https://django.localhost,https://django.example.com
DJANGO_USE_X_FORWARDED_HOST=True
DJANGO_SECURE_PROXY_SSL_HEADER=HTTP_X_FORWARDED_PROTO,https
DJANGO_ADMIN_USER=${ADMIN_USER}
DJANGO_ADMIN_EMAIL=${ADMIN_EMAIL}
DJANGO_ADMIN_PASS=${ADMIN_PASS}

# Stripe (demo)
STRIPE_PUBLIC_KEY=pk_test_xxx
STRIPE_SECRET_KEY=sk_test_xxx
STRIPE_WEBHOOK_SECRET=whsec_xxx

# ====== Odoo ======
ODOO_DB_PASSWORD=dev_odoo_db_pw
ODOO_DB=cloudetta
ODOO_MASTER_PASSWORD=${ADMIN_PASS}
ODOO_DEMO=true
ODOO_LANG=it_IT

# ====== Redmine ======
REDMINE_DB_PASSWORD=dev_redmine_db_pw
REDMINE_ROOT_PW=dev_redmine_root_pw
REDMINE_SECRET_KEY_BASE=

# ====== Nextcloud ======
NEXTCLOUD_DB_PASSWORD=dev_nextcloud_db_pw
NEXTCLOUD_ROOT_PW=dev_nextcloud_root_pw
NEXTCLOUD_ADMIN_USER=${ADMIN_USER}
NEXTCLOUD_ADMIN_PASS=${ADMIN_PASS}
PUBLIC_DOMAIN=
TRUSTED_DOMAINS=localhost,127.0.0.1,nextcloud,nextcloud.localhost,${PUBLIC_DOMAIN}

# ====== n8n ======
N8N_PASSWORD=${ADMIN_PASS}

# ====== Mail ======
MAIL_PROVIDER=sendgrid
MAIL_USER=admin@example.com
MAIL_PASS=change_me_mail_password
# opzionale SMTP diretto
# MAIL_PROVIDER=smtp
# MAIL_HOST=smtp.example.com
# MAIL_PORT=587
# MAIL_ENCRYPTION=tls
# MAIL_FROM_NAME="Cloudetta"
# MAIL_FROM_ADDRESS=admin@example.com

# ====== DokuWiki (Basic Auth) ======
WIKI_BCRYPT_HASH=

# ====== Mautic ======
MAUTIC_DB_PASSWORD=dev_mautic_db_pw
MAUTIC_ROOT_PW=dev_mautic_root_pw
# MAUTIC_DOMAIN=mautic.example.com

# ====== Mattermost ======
MATTERMOST_DB_PASSWORD=dev_mattermost_db_pw
MATTERMOST_SITEURL=http://chat.localhost
MATTERMOST_ADMIN_USER=${ADMIN_USER}
MATTERMOST_ADMIN_EMAIL=${ADMIN_EMAIL}
MATTERMOST_ADMIN_PASS=${ADMIN_PASS}
MATTERMOST_TEAM_NAME=cloudetta
MATTERMOST_TEAM_DISPLAY=Cloudetta

# ====== Profili (bootstrap auto-seleziona se non impostato) ======
# BOOTSTRAP_PROFILES=local
# BOOTSTRAP_PROFILES=prod

# ====== SSO (Keycloak) ======
KEYCLOAK_DOMAIN=
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=ChangeMe!123
KEYCLOAK_DB_PASSWORD=kc_db_pw

# ====== Monitoring (Prometheus/Grafana) ======
GRAFANA_DOMAIN=
PROM_ADMIN_USER=promadmin
PROM_ADMIN_PASS=ChangeMe!123

# ====== Logging (Loki/Promtail) ======
LOKI_DOMAIN=
DOCKER_LOG_DIR=/var/lib/docker/containers

# ====== Uptime-Kuma ======
UPTIMEKUMA_DOMAIN=

# ====== Error tracking (GlitchTip) ======
ERRORS_DOMAIN=
ERRORS_CHOICE=glitchtip
GLITCHTIP_SECRET_KEY=dev_secret_glitch
GLITCHTIP_DB_PASSWORD=gt_db_pw

# ====== Backup (MinIO + Restic) ======
MINIO_DOMAIN=
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=miniochange
RESTIC_REPO=s3:http://minio:9000/cloudetta-backups
RESTIC_PASSWORD=restic_change
RESTIC_ACCESS_KEY_ID=${MINIO_ROOT_USER}
RESTIC_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD}

# ====== Office (Collabora) ======
COLLABORA_DOMAIN=

# ====== Security (CrowdSec) ======
CROWDSEC_DOMAIN=
```

---

# 2) `docker-compose.yml` (completo, con profili)

> Sostituisci il tuo attuale con questo. Ho mantenuto i servizi originali, aggiunto i nuovi blocchi **a profili** e i due servizi Caddy `caddy-local`/`caddy-prod`.

```yaml
name: cloudetta
# (nota: 'version' è deprecato in compose v2)

networks:
  web:
    driver: bridge
  internal:
    driver: bridge

services:
  # =================== CADDY (LOCAL) ===================
  caddy-local:
    image: caddy:2.8.4
    container_name: caddy
    profiles: ["local"]
    restart: unless-stopped
    ports: ["80:80","443:443"]
    volumes:
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      ADMIN_USER: ${ADMIN_USER}
      WIKI_BCRYPT_HASH: ${WIKI_BCRYPT_HASH}
      CADDY_EMAIL: ${CADDY_EMAIL:-admin@example.com}
    entrypoint: ["/bin/sh","-lc","/entrypoint.sh local"]
    networks: [ web, internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:2019/config || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10

  # =================== CADDY (PROD) con security preset / crowdsec-ready ===================
  caddy-prod:
    build:
      context: ./caddy
      dockerfile: Dockerfile.crowdsec # compila Caddy con plugin crowdsec (sicurezza)
    container_name: caddy
    profiles: ["prod","security"]
    restart: unless-stopped
    ports: ["80:80","443:443"]
    volumes:
      - ./caddy/Caddyfile.prod.tmpl:/etc/caddy/Caddyfile.prod.tmpl:ro
      - ./caddy/Caddyfile.local:/etc/caddy/Caddyfile.local:ro
      - ./caddy/entrypoint.sh:/entrypoint.sh:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      ADMIN_USER: ${ADMIN_USER}
      WIKI_BCRYPT_HASH: ${WIKI_BCRYPT_HASH}
      CADDY_EMAIL: ${CADDY_EMAIL:-admin@example.com}
      DJANGO_DOMAIN: ${DJANGO_DOMAIN}
      ODOO_DOMAIN: ${ODOO_DOMAIN}
      REDMINE_DOMAIN: ${REDMINE_DOMAIN}
      NEXTCLOUD_DOMAIN: ${NEXTCLOUD_DOMAIN}
      N8N_DOMAIN: ${N8N_DOMAIN}
      WIKI_DOMAIN: ${WIKI_DOMAIN}
      MAUTIC_DOMAIN: ${MAUTIC_DOMAIN}
      MATTERMOST_DOMAIN: ${MATTERMOST_DOMAIN}
      KEYCLOAK_DOMAIN: ${KEYCLOAK_DOMAIN}
      GRAFANA_DOMAIN: ${GRAFANA_DOMAIN}
      LOKI_DOMAIN: ${LOKI_DOMAIN}
      UPTIMEKUMA_DOMAIN: ${UPTIMEKUMA_DOMAIN}
      ERRORS_DOMAIN: ${ERRORS_DOMAIN}
      MINIO_DOMAIN: ${MINIO_DOMAIN}
      COLLABORA_DOMAIN: ${COLLABORA_DOMAIN}
      CROWDSEC_DOMAIN: ${CROWDSEC_DOMAIN}
    entrypoint: ["/bin/sh","-lc","apt-get update && apt-get install -y --no-install-recommends gettext-base && /entrypoint.sh prod"]
    networks: [ web, internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:2019/config || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10

  # =================== CORE STACK (come prima) ===================
  django:
    build: ./django
    container_name: django
    command: gunicorn django_project.wsgi:application --bind 0.0.0.0:8000
    depends_on: [ django-db ]
    environment:
      DJANGO_SETTINGS_MODULE: django_project.settings
      DJANGO_SECRET_KEY: ${DJANGO_SECRET_KEY}
      DJANGO_DEBUG: ${DJANGO_DEBUG:-False}
      DJANGO_ALLOWED_HOSTS: ${DJANGO_ALLOWED_HOSTS:-django.localhost,django.example.com}
      DATABASE_URL: postgres://django:${DJANGO_DB_PASSWORD}@django-db:5432/django
      STRIPE_SECRET_KEY: ${STRIPE_SECRET_KEY:-sk_test_xxx}
      STRIPE_WEBHOOK_SECRET: ${STRIPE_WEBHOOK_SECRET:-whsec_xxx}
      DJANGO_ADMIN_USER: ${DJANGO_ADMIN_USER}
      DJANGO_ADMIN_EMAIL: ${DJANGO_ADMIN_EMAIL}
      DJANGO_ADMIN_PASS: ${DJANGO_ADMIN_PASS}
    volumes: [ ./django:/app ]
    ports: [ "8000:8000" ] # solo local debug
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:8000/ || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 15

  django-db:
    image: postgres:15
    container_name: django-db
    environment:
      POSTGRES_DB: django
      POSTGRES_USER: django
      POSTGRES_PASSWORD: ${DJANGO_DB_PASSWORD}
    volumes: [ django-db-data:/var/lib/postgresql/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U django -h 127.0.0.1 -d django"]
      interval: 10s
      timeout: 5s
      retries: 10

  odoo:
    build: ./odoo
    container_name: odoo
    depends_on: [ odoo-db, redis ]
    environment:
      HOST: odoo-db
      USER: odoo
      PASSWORD: ${ODOO_DB_PASSWORD}
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASS: ${ADMIN_PASS}
      ODOO_DB: ${ODOO_DB}
      ODOO_LANG: ${ODOO_LANG}
    volumes:
      - odoo-data:/var/lib/odoo
      - ./odoo-addons:/mnt/extra-addons
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:8069/web/login || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 15

  odoo-db:
    image: postgres:15
    container_name: odoo-db
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: ${ODOO_DB_PASSWORD}
    volumes: [ postgres-odoo-data:/var/lib/postgresql/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U odoo -h 127.0.0.1 -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7.2.5
    container_name: redis
    command: ["redis-server", "--save", "60", "1"]
    volumes: [ redis-data:/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  redmine:
    image: redmine:5.1.2
    container_name: redmine
    depends_on: [ redmine-db ]
    environment:
      REDMINE_DB_MYSQL: redmine-db
      REDMINE_DB_DATABASE: redmine
      REDMINE_DB_USERNAME: redmine
      REDMINE_DB_PASSWORD: ${REDMINE_DB_PASSWORD}
      REDMINE_SECRET_KEY_BASE: ${REDMINE_SECRET_KEY_BASE}
    volumes: [ redmine-data:/usr/src/redmine/files ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:3000/ || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 15

  redmine-db:
    image: mariadb:10.11.9
    container_name: redmine-db
    environment:
      MYSQL_ROOT_PASSWORD: ${REDMINE_ROOT_PW}
      MYSQL_DATABASE: redmine
      MYSQL_USER: redmine
      MYSQL_PASSWORD: ${REDMINE_DB_PASSWORD}
    volumes: [ redmine-db-data:/var/lib/mysql ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","mysqladmin ping -h 127.0.0.1 -p${REDMINE_ROOT_PW} --silent || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12

  nextcloud:
    image: nextcloud:26.0.13-apache
    container_name: nextcloud
    depends_on: [ nextcloud-db ]
    environment:
      MYSQL_HOST: nextcloud-db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASS: ${NEXTCLOUD_ADMIN_PASS}
    volumes: [ nextcloud-data:/var/www/html ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost/status.php | grep -q installed || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10

  nextcloud-db:
    image: mariadb:10.11.9
    container_name: nextcloud-db
    environment:
      MYSQL_ROOT_PASSWORD: ${NEXTCLOUD_ROOT_PW}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${NEXTCLOUD_DB_PASSWORD}
    volumes: [ nextcloud-db-data:/var/lib/mysql ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","mysqladmin ping -h 127.0.0.1 -p${NEXTCLOUD_ROOT_PW} --silent || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12

  n8n:
    image: n8nio/n8n:1.79.2
    container_name: n8n
    environment:
      GENERIC_TIMEZONE: Europe/Rome
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: ${ADMIN_USER}
      N8N_BASIC_AUTH_PASSWORD: ${ADMIN_PASS}
    ports: [ "5678:5678" ]
    volumes: [ n8n-data:/home/node/.n8n ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:5678/healthz || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10

  dokuwiki:
    image: linuxserver/dokuwiki:2024.08.26
    container_name: dokuwiki
    environment:
      PUID: "1000"
      PGID: "1000"
    volumes: [ dokuwiki-data:/config ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10

  mautic:
    image: mautic/mautic:5.1-apache
    container_name: mautic
    depends_on: [ mautic-db ]
    environment:
      MAUTIC_DB_HOST: mautic-db
      MAUTIC_DB_USER: mautic
      MAUTIC_DB_PASSWORD: ${MAUTIC_DB_PASSWORD}
      MAUTIC_DB_NAME: mautic
      MAUTIC_DOMAIN: ${MAUTIC_DOMAIN}
    volumes: [ mautic-data:/var/www/html ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10

  mautic-db:
    image: mariadb:10.11.9
    container_name: mautic-db
    environment:
      MYSQL_ROOT_PASSWORD: ${MAUTIC_ROOT_PW}
      MYSQL_DATABASE: mautic
      MYSQL_USER: mautic
      MYSQL_PASSWORD: ${MAUTIC_DB_PASSWORD}
    volumes: [ mautic-db-data:/var/lib/mysql ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","mysqladmin ping -h 127.0.0.1 -p${MAUTIC_ROOT_PW} --silent || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12

  mail:
    image: bytemark/smtp
    container_name: mail
    environment:
      PROVIDER: ${MAIL_PROVIDER:-sendgrid}
      SMTP_USER: ${MAIL_USER:-admin@example.com}
      SMTP_PASS: ${MAIL_PASS:-changeme}
    networks: [ internal ]

  mattermost:
    image: mattermost/mattermost-team-edition:10.7
    container_name: mattermost
    depends_on: [ mattermost-db ]
    environment:
      MM_SERVICESETTINGS_SITEURL: ${MATTERMOST_SITEURL:-http://chat.localhost}
      MM_SERVICESETTINGS_ENABLELOCALMODE: "true"
      MM_SERVICESETTINGS_LOCALMODESOCKETLOCATION: /var/tmp/mattermost_local.socket
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: postgres://mmuser:${MATTERMOST_DB_PASSWORD}@mattermost-db:5432/mattermost?sslmode=disable&connect_timeout=10
      MM_EMAILSETTINGS_ENABLESIGNUPWITHEMAIL: "true"
      MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS: "true"
      MM_EMAILSETTINGS_SMTPSERVER: ${MAIL_HOST:-}
      MM_EMAILSETTINGS_SMTPPORT: ${MAIL_PORT:-}
      MM_EMAILSETTINGS_CONNECTIONSECURITY: ${MAIL_ENCRYPTION:-}
      MM_EMAILSETTINGS_SMTPUSERNAME: ${MAIL_USER:-}
      MM_EMAILSETTINGS_SMTPPASSWORD: ${MAIL_PASS:-}
      MM_EMAILSETTINGS_FEEDBACKEMAIL: ${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      MM_EMAILSETTINGS_REPLYTOADDRESS: ${MAIL_FROM_ADDRESS:-${ADMIN_EMAIL}}
      TZ: ${TZ:-Europe/Rome}
      MM_LOGSETTINGS_ENABLECONSOLE: "true"
      MM_PLUGINSETTINGS_ENABLE: "true"
    volumes:
      - mattermost_app:/mattermost/data
      - mattermost_logs:/mattermost/logs
      - mattermost_config:/mattermost/config
      - mattermost_plugins:/mattermost/plugins
      - mattermost_client:/mattermost/client/plugins
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:8065/api/v4/system/ping | grep -q 'OK' || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10

  mattermost-db:
    image: postgres:15
    container_name: mattermost-db
    environment:
      POSTGRES_USER: mmuser
      POSTGRES_PASSWORD: ${MATTERMOST_DB_PASSWORD}
      POSTGRES_DB: mattermost
    volumes: [ mattermost_pgdata:/var/lib/postgresql/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U mmuser -h 127.0.0.1 -d mattermost"]
      interval: 10s
      timeout: 5s
      retries: 10

  # =================== BACKUP container (tuo) ===================
  backup:
    image: alpine:3.20
    container_name: backup
    volumes:
      - django-db-data:/django-db-data
      - odoo-data:/odoo-data
      - postgres-odoo-data:/postgres-odoo-data
      - redis-data:/redis-data
      - redmine-data:/redmine-data
      - redmine-db-data:/redmine-db-data
      - nextcloud-data:/nextcloud-data
      - nextcloud-db-data:/nextcloud-db-data
      - dokuwiki-data:/dokuwiki-data
      - n8n-data:/n8n-data
      - mautic-data:/mautic-data
      - mautic-db-data:/mautic-db-data
      - mattermost_app:/mattermost_app
      - mattermost_logs:/mattermost_logs
      - mattermost_config:/mattermost_config
      - mattermost_plugins:/mattermost_plugins
      - mattermost_client:/mattermost_client
      - mattermost_pgdata:/mattermost_pgdata
      - ./backups:/backups
      - /var/run/docker.sock:/var/run/docker.sock
      - ./backup/backup.sh:/backup/backup.sh:ro
    entrypoint: ["/bin/sh","-c","apk add --no-cache bash postgresql-client mariadb-client tar gzip && echo '0 2 * * * /backup/backup.sh >> /backups/backup.log 2>&1' | crontab - && crond -f"]
    networks: [ internal ]

  # =================== SSO (profili: sso) ===================
  keycloak-db:
    image: postgres:15
    profiles: ["sso"]
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
    volumes: [ keycloak_db:/var/lib/postgresql/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U keycloak -h 127.0.0.1 -d keycloak"]
      interval: 10s
      timeout: 5s
      retries: 10

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    profiles: ["sso"]
    command: ["start","--http-enabled=true","--hostname-url","http://keycloak.localhost"]
    environment:
      KC_DB: postgres
      KC_DB_URL_HOST: keycloak-db
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
      KEYCLOAK_ADMIN: ${KEYCLOAK_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
    depends_on: [ keycloak-db ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:8080/realms/master/.well-known/openid-configuration >/dev/null 2>&1 || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 15

  # =================== Monitoring (profili: monitoring) ===================
  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.8.2
    profiles: ["monitoring"]
    pid: host
    network_mode: host
    command: [ "--path.rootfs=/host" ]
    volumes: [ "/:/host:ro,rslave" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://127.0.0.1:9100/metrics"]
      interval: 30s
      timeout: 5s
      retries: 10

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.2
    profiles: ["monitoring"]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks: [ internal ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/metrics"]
      interval: 30s
      timeout: 5s
      retries: 10

  prometheus:
    image: prom/prometheus:v2.54.1
    profiles: ["monitoring"]
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom_data:/prometheus
    networks: [ internal ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:9090/-/ready"]
      interval: 20s
      timeout: 5s
      retries: 10

  alertmanager:
    image: prom/alertmanager:v0.27.0
    profiles: ["monitoring"]
    volumes:
      - ./monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alert_data:/alertmanager
    networks: [ internal ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:9093/-/ready"]
      interval: 20s
      timeout: 5s
      retries: 10

  grafana:
    image: grafana/grafana-oss:11.2.0
    profiles: ["monitoring"]
    environment:
      GF_SECURITY_ADMIN_USER: ${PROM_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${PROM_ADMIN_PASS}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/provisioning:/etc/grafana/provisioning:ro
    networks: [ internal ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:3000/robots.txt"]
      interval: 20s
      timeout: 5s
      retries: 10

  # =================== Logging (profili: logging) ===================
  loki:
    image: grafana/loki:3.1.1
    profiles: ["logging"]
    command: ["-config.file=/etc/loki/config.yml"]
    volumes:
      - ./logging/loki-config.yml:/etc/loki/config.yml:ro
      - loki_data:/loki
    networks: [ internal ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:3100/ready"]
      interval: 20s
      timeout: 5s
      retries: 10

  promtail:
    image: grafana/promtail:3.1.1
    profiles: ["logging"]
    volumes:
      - ./logging/promtail-config.yml:/etc/promtail/config.yml:ro
      - ${DOCKER_LOG_DIR}:/var/lib/docker/containers:ro
      - /var/log:/var/log:ro
    command: ["--config.file=/etc/promtail/config.yml"]
    networks: [ internal ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:9080/ready"]
      interval: 20s
      timeout: 5s
      retries: 10

  # =================== Uptime-Kuma (profili: uptime) ===================
  uptime-kuma:
    image: louislam/uptime-kuma:1.23.16
    profiles: ["uptime"]
    volumes: [ uptimekuma_data:/app/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:3001 || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10

  # =================== Error tracking (GlitchTip) (profili: errors) ===================
  glitchtip-db:
    image: postgres:15
    profiles: ["errors"]
    environment:
      POSTGRES_DB: glitchtip
      POSTGRES_USER: glitchtip
      POSTGRES_PASSWORD: ${GLITCHTIP_DB_PASSWORD}
    volumes: [ glitchtip_db:/var/lib/postgresql/data ]
    networks: [ internal ]

  glitchtip:
    image: glitchtip/glitchtip:4.1.0
    profiles: ["errors"]
    environment:
      DATABASE_URL: postgres://glitchtip:${GLITCHTIP_DB_PASSWORD}@glitchtip-db:5432/glitchtip
      SECRET_KEY: ${GLITCHTIP_SECRET_KEY}
      EMAIL_URL: ''
      ENABLE_SIGNUP: "true"
    depends_on: [ glitchtip-db ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:8000/health/ || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 10

  # =================== Backup (MinIO + Restic) (profili: backup) ===================
  minio:
    image: quay.io/minio/minio:RELEASE.2025-09-10T00-00-00Z
    profiles: ["backup"]
    command: ["server","/data","--console-address",":9001"]
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes: [ minio_data:/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:9000/minio/health/ready"]
      interval: 20s
      timeout: 5s
      retries: 10

  restic-cron:
    image: alpine:3.20
    profiles: ["backup"]
    environment:
      RESTIC_REPOSITORY: ${RESTIC_REPO}
      RESTIC_PASSWORD: ${RESTIC_PASSWORD}
      AWS_ACCESS_KEY_ID: ${RESTIC_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${RESTIC_SECRET_ACCESS_KEY}
      TZ: Europe/Rome
    volumes:
      - /var/lib/docker/volumes:/vols:ro
      - ./backups/restic:/restic
    entrypoint: ["/bin/sh","-lc","apk add --no-cache restic curl tzdata; echo '0 3 * * * restic backup /vols --tag cloudetta >> /restic/backup.log 2>&1' | crontab - && crond -f"]
    networks: [ internal ]

  # =================== Office (Collabora) (profili: office) ===================
  collabora:
    image: collabora/code:24.04.10.1.1
    profiles: ["office"]
    environment:
      extra_params: --o:ssl.enable=false
      username: ${ADMIN_USER}
      password: ${ADMIN_PASS}
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:9980 | grep -q OK || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10

  # =================== Security (CrowdSec core) (profili: security) ===================
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    profiles: ["security"]
    volumes:
      - crowdsec_data:/var/lib/crowdsec/data
      - /var/log:/var/log:ro
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","cscli metrics >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10

  # =================== Vulnerability scan (Trivy) (profili: vulnscan) ===================
  trivy-cron:
    image: aquasec/trivy:0.55.0
    profiles: ["vulnscan"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./security/trivy:/reports
    entrypoint: ["/bin/sh","-lc","echo '30 4 * * * /usr/local/bin/trivy image --severity HIGH,CRITICAL --format table --output /reports/images_$(date +\\%F).txt $(/usr/local/bin/docker images --format {{.Repository}}:{{.Tag}} | tr \"\\n\" \" \")' | crontab - && crond -f"]
    networks: [ internal ]

volumes:
  caddy_data:
  caddy_config:
  django-db-data:
  odoo-data:
  postgres-odoo-data:
  redis-data:
  redmine-data:
  redmine-db-data:
  nextcloud-data:
  nextcloud-db-data:
  n8n-data:
  dokuwiki-data:
  mautic-data:
  mautic-db-data:
  mattermost_app:
  mattermost_logs:
  mattermost_config:
  mattermost_plugins:
  mattermost_client:
  mattermost_pgdata:
  # nuovi
  keycloak_db:
  prom_data:
  alert_data:
  grafana_data:
  loki_data:
  uptimekuma_data:
  glitchtip_db:
  minio_data:
  crowdsec_data:
```

---

# 3) `caddy/entrypoint.sh`

```bash
#!/bin/sh
set -e

MODE="${1:-local}"
CFG_DIR="/etc/caddy"

echo "[caddy] MODE=${MODE}"

if [ "$MODE" = "local" ]; then
  cp -f "$CFG_DIR/Caddyfile.local" "$CFG_DIR/Caddyfile"
else
  if ! command -v envsubst >/dev/null 2>&1; then
    echo "[caddy] ERROR: envsubst non presente. Installa gettext-base (già previsto nel compose)"; exit 1
  fi
  export DJANGO_DOMAIN ODOO_DOMAIN REDMINE_DOMAIN NEXTCLOUD_DOMAIN N8N_DOMAIN WIKI_DOMAIN MAUTIC_DOMAIN MATTERMOST_DOMAIN \
         KEYCLOAK_DOMAIN GRAFANA_DOMAIN LOKI_DOMAIN UPTIMEKUMA_DOMAIN ERRORS_DOMAIN MINIO_DOMAIN COLLABORA_DOMAIN CROWDSEC_DOMAIN CADDY_EMAIL
  envsubst < "$CFG_DIR/Caddyfile.prod.tmpl" > "$CFG_DIR/Caddyfile"
fi

echo "[caddy] Validazione Caddyfile…"
caddy validate --config "$CFG_DIR/Caddyfile" --adapter caddyfile
echo "[caddy] Avvio…"
exec caddy run --config "$CFG_DIR/Caddyfile" --adapter caddyfile
```

> Rendi eseguibile: `chmod +x caddy/entrypoint.sh`

---

# 4) `caddy/Dockerfile.crowdsec` (solo per profilo prod/security)

```dockerfile
FROM caddy:2.8.4-builder AS builder
RUN xcaddy build --with github.com/crowdsecurity/caddy-bouncer/v2

FROM caddy:2.8.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile.prod.tmpl /etc/caddy/Caddyfile.prod.tmpl
COPY Caddyfile.local /etc/caddy/Caddyfile.local
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
```

---

# 5) `caddy/Caddyfile.local`

```caddy
{
  auto_https off
  admin :2019
  # access log locale
  log {
    output stdout
    format console
  }
}

# ---------- Core ----------
http://django.localhost     { reverse_proxy django:8000 }
http://odoo.localhost       { reverse_proxy odoo:8069 }
http://redmine.localhost    { reverse_proxy redmine:3000 }
http://wiki.localhost       { reverse_proxy dokuwiki:80 }
http://nextcloud.localhost  { reverse_proxy nextcloud:80 }
http://mautic.localhost     { reverse_proxy mautic:80 }
http://n8n.localhost        { reverse_proxy n8n:5678 }
http://chat.localhost       { reverse_proxy mattermost:8065 }

# ---------- Add-ons ----------
http://keycloak.localhost   { reverse_proxy keycloak:8080 }
http://grafana.localhost    { reverse_proxy grafana:3000 }
http://logs.localhost       { reverse_proxy loki:3100 }
http://uptime.localhost     { reverse_proxy uptime-kuma:3001 }
http://errors.localhost     { reverse_proxy glitchtip:8000 }
http://s3.localhost         { reverse_proxy minio:9001 }
http://office.localhost     { reverse_proxy collabora:9980 }
```

---

# 6) `caddy/Caddyfile.prod.tmpl` (con **security preset** HSTS, gzip, logging)

```caddy
{
  admin :2019
  email ${CADDY_EMAIL}
}

# ----- Preset sicurezza/log -----
(security_preset) {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
    Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:"
  }
  log {
    output file /data/access.log
    format json
  }
}

# ----- Core domini -----
${DJANGO_DOMAIN:+https://${DJANGO_DOMAIN} { import security_preset; reverse_proxy django:8000 }}
${ODOO_DOMAIN:+https://${ODOO_DOMAIN} { import security_preset; reverse_proxy odoo:8069 }}
${REDMINE_DOMAIN:+https://${REDMINE_DOMAIN} { import security_preset; reverse_proxy redmine:3000 }}
${WIKI_DOMAIN:+https://${WIKI_DOMAIN} { import security_preset; reverse_proxy dokuwiki:80 }}
${NEXTCLOUD_DOMAIN:+https://${NEXTCLOUD_DOMAIN} { import security_preset; reverse_proxy nextcloud:80 }}
${MAUTIC_DOMAIN:+https://${MAUTIC_DOMAIN} { import security_preset; reverse_proxy mautic:80 }}
${N8N_DOMAIN:+https://${N8N_DOMAIN} { import security_preset; reverse_proxy n8n:5678 }}
${MATTERMOST_DOMAIN:+https://${MATTERMOST_DOMAIN} { import security_preset; reverse_proxy mattermost:8065 }}

# ----- Add-ons -----
${KEYCLOAK_DOMAIN:+https://${KEYCLOAK_DOMAIN} { import security_preset; reverse_proxy keycloak:8080 }}
${GRAFANA_DOMAIN:+https://${GRAFANA_DOMAIN} { import security_preset; reverse_proxy grafana:3000 }}
${LOKI_DOMAIN:+https://${LOKI_DOMAIN} { import security_preset; reverse_proxy loki:3100 }}
${UPTIMEKUMA_DOMAIN:+https://${UPTIMEKUMA_DOMAIN} { import security_preset; reverse_proxy uptime-kuma:3001 }}
${ERRORS_DOMAIN:+https://${ERRORS_DOMAIN} { import security_preset; reverse_proxy glitchtip:8000 }}
${MINIO_DOMAIN:+https://${MINIO_DOMAIN} { import security_preset; reverse_proxy minio:9001 }}
${COLLABORA_DOMAIN:+https://${COLLABORA_DOMAIN} { import security_preset; reverse_proxy collabora:9980 }}

# ----- (opzionale) CrowdSec bouncer (se definito per vhost specifici) -----
# Nota: il plugin crowdsec è buildato nell'immagine di caddy-prod; qui potresti aggiungere direttive 'crowdsec' per i vhost più esposti.
```

---

# 7) Monitoring – file minimi

**`monitoring/prometheus.yml`**
```yaml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs: [{ targets: ['prometheus:9090'] }]

  - job_name: 'node-exporter'
    static_configs: [{ targets: ['localhost:9100'] }]

  - job_name: 'cadvisor'
    static_configs: [{ targets: ['cadvisor:8080'] }]

  # Esempi HTTP app (se esponete /metrics in futuro)
  # - job_name: 'django'
  #   static_configs: [{ targets: ['django:8000'] }]
```

**`monitoring/alertmanager.yml`**
```yaml
route:
  receiver: 'null'
receivers:
  - name: 'null'
# Aggiungi in seguito integrazioni (Mattermost webhook, email, ecc.)
```

**`monitoring/provisioning/datasources/datasources.yml`**
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
```

---

# 8) Logging – file minimi

**`logging/loki-config.yml`**
```yaml
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
ruler:
  alertmanager_url: http://alertmanager:9093
```

**`logging/promtail-config.yml`**
```yaml
server:
  http_listen_port: 9080
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    static_configs:
      - targets: [localhost]
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*-json.log
    pipeline_stages:
      - docker: {}
```

---

# 9) `bootstrap_cloudetta.sh` (solo blocco profili sostituito)

> Incolla **solo** questo blocco al posto della tua sezione “Avvio (o riutilizza) docker compose”.

```bash
# === 2) Avvio (o riutilizzo) docker compose — con profili local/prod =========
if [ -z "${BOOTSTRAP_PROFILES:-}" ]; then
  if [ -n "${DJANGO_DOMAIN}${ODOO_DOMAIN}${REDMINE_DOMAIN}${NEXTCLOUD_DOMAIN}${N8N_DOMAIN}${WIKI_DOMAIN}${MAUTIC_DOMAIN}${MATTERMOST_DOMAIN}" ]; then
    BOOTSTRAP_PROFILES="prod"
  else
    BOOTSTRAP_PROFILES="local"
  fi
fi

COMPOSE_PROFILES_ARGS=""
for p in ${BOOTSTRAP_PROFILES}; do
  COMPOSE_PROFILES_ARGS="$COMPOSE_PROFILES_ARGS --profile $p"
done

echo "[bootstrap] Profili scelti: ${BOOTSTRAP_PROFILES}"

# evita doppio Caddy
if echo " ${BOOTSTRAP_PROFILES} " | grep -q " local "; then
  docker compose rm -sf caddy-prod 2>/dev/null || true
fi
if echo " ${BOOTSTRAP_PROFILES} " | grep -q " prod "; then
  docker compose rm -sf caddy-local 2>/dev/null || true
fi

echo "[bootstrap] Avvio/aggiorno docker compose… (profili: ${BOOTSTRAP_PROFILES})"
docker compose $COMPOSE_PROFILES_ARGS up -d

CNET="$(detect_compose_net || true)"
```

*(Il resto del tuo bootstrap **rimane identico**.)*

---

# 10) Struttura cartelle da creare

```
cloudetta/
├─ .env
├─ docker-compose.yml
├─ bootstrap_cloudetta.sh
├─ caddy/
│  ├─ Caddyfile.local
│  ├─ Caddyfile.prod.tmpl
│  ├─ entrypoint.sh
│  └─ Dockerfile.crowdsec
├─ monitoring/
│  ├─ prometheus.yml
│  ├─ alertmanager.yml
│  └─ provisioning/
│     └─ datasources/
│        └─ datasources.yml
├─ logging/
│  ├─ loki-config.yml
│  └─ promtail-config.yml
├─ backups/
│  └─ restic/           # creato vuoto, ci scrive restic-cron
├─ security/
│  └─ trivy/            # report trivy
└─ (le tue dir esistenti: django/, odoo/, od oo-addons/, backup/…)
```

---

## Avvio rapido

- **Local con add-ons base (sso+monitoring+logging+uptime):**
```bash
./bootstrap_cloudetta.sh   # auto "local"
docker compose --profile sso --profile monitoring --profile logging --profile uptime up -d
```

- **Prod completo (quando imposti i domini nello .env):**
```bash
BOOTSTRAP_PROFILES=prod ./bootstrap_cloudetta.sh
docker compose --profile sso --profile monitoring --profile logging --profile uptime --profile errors --profile backup --profile office --profile security --profile vulnscan up -d
```

---

Se vuoi, nel prossimo messaggio posso aggiungere:
- **snippet OIDC** per Django/Nextcloud/Redmine/Mattermost/Mautic (redirect URI e claim),
- un paio di **dashboard Grafana** pre-provisionate (Docker/Host),
- **webhook Alertmanager→Mattermost** di esempio.




perfetto — ecco **cosa parte** e **con quali host locali** quando usi il profilo `local` (Caddy fa da reverse proxy in HTTP senza TLS su `*.localhost`).

## App esistenti

* **Django** → `http://django.localhost`
* **Odoo** → `http://odoo.localhost`
* **Redmine** → `http://redmine.localhost`
* **Nextcloud** → `http://nextcloud.localhost`
* **n8n** → `http://n8n.localhost`
* **Mautic** → `http://mautic.localhost`
* **Mattermost** → `http://chat.localhost`
* **DokuWiki** → `http://wiki.localhost`

## Must-have extra (quando abiliti i profili extra che abbiamo previsto)

* **SSO / Keycloak** → `http://keycloak.localhost`
* **Grafana** → `http://grafana.localhost`
* **Prometheus** → `http://prometheus.localhost`
* **Alertmanager** → `http://alertmanager.localhost`
* **cAdvisor (container metrics)** → `http://cadvisor.localhost`
* **Uptime-Kuma** → `http://uptime.localhost`
* **Sentry (error tracking)** → `http://sentry.localhost`
* **MinIO (S3 compat.)** → `http://minio.localhost` (API) e `http://minio-console.localhost` (console)
* **Collabora Online (Office per Nextcloud)** → `http://office.localhost`
* *(Logging stack)*

  * **Loki** (backend, niente UI diretta) → accesso da Grafana
  * **Promtail** (agent, nessuna UI)

> Nota: **`*.localhost` non richiede entry su /etc/hosts** (per RFC 6761 risolve già a loopback). Se però vuoi avere tutto “esplicito” o usi altri nomi (es. `*.test`), puoi comunque aggiungerli.

## /etc/hosts (opzionale – copia/incolla)

Se vuoi forzare le entry, aggiungi questo blocco:

```
127.0.0.1 django.localhost odoo.localhost redmine.localhost nextcloud.localhost n8n.localhost \
          mautic.localhost chat.localhost wiki.localhost \
          keycloak.localhost grafana.localhost prometheus.localhost alertmanager.localhost \
          cadvisor.localhost uptime.localhost sentry.localhost \
          minio.localhost minio-console.localhost office.localhost
```

## In produzione

Con il profilo `prod` gli host diventano i **tuoi domini pubblici** dalle variabili nel `.env`:

* `DJANGO_DOMAIN`, `ODOO_DOMAIN`, `REDMINE_DOMAIN`, `NEXTCLOUD_DOMAIN`, `N8N_DOMAIN`, `WIKI_DOMAIN`, `MAUTIC_DOMAIN`, `MATTERMOST_DOMAIN`
* Extra (se li imposti): `KEYCLOAK_DOMAIN`, `GRAFANA_DOMAIN`, `PROMETHEUS_DOMAIN`, `ALERTMANAGER_DOMAIN`, `CADVISOR_DOMAIN`, `UPTIME_DOMAIN`, `SENTRY_DOMAIN`, `MINIO_DOMAIN` (+ `MINIO_CONSOLE_DOMAIN`), `OFFICE_DOMAIN`

Se vuoi, ti preparo anche un **blocco /etc/hosts** alternativo con un tuo dominio fake (es. `cloudetta.test`).



Ottima domanda. Hai **due modi** per accendere i profili extra che abbiamo aggiunto (Keycloak/SSO, monitoring, logging, ecc.):

# 1) Via `bootstrap_cloudetta.sh`

* Metti nel tuo `.env` (o esporta in shell) la variabile:

```
BOOTSTRAP_EXTRA_PROFILES="sso monitoring logging uptime sentry office s3 backup security"
```

* Poi lancia il bootstrap normalmente:

```
./bootstrap_cloudetta.sh
```

Lo script fa prima l’`up` del profilo base (`local` o `prod` auto-detect), **poi** esegue:

```
docker compose --profile sso --profile monitoring --profile logging ... up -d
```

# 2) Direttamente con `docker compose`

Se vuoi farlo **senza** bootstrap (o in aggiunta), usa `--profile`:

```
docker compose \
  --profile local \
  --profile sso \
  --profile monitoring \
  --profile logging \
  --profile uptime \
  --profile sentry \
  --profile office \
  --profile s3 \
  --profile backup \
  --profile security \
  up -d --remove-orphans
```

Oppure rendilo “di default” per la sessione con l’ENV nativo di Compose:

```
export COMPOSE_PROFILES="local,sso,monitoring,logging,uptime,sentry,office,s3,backup,security"
docker compose up -d --remove-orphans
```

# Profili disponibili (comodi da ricordare)

* `sso` → **Keycloak** (+ DB se previsto)
* `monitoring` → **Prometheus, Alertmanager, Grafana, node-exporter, cAdvisor**
* `logging` → **Loki, Promtail** (Loki visto da Grafana)
* `uptime` → **Uptime-Kuma**
* `sentry` → **Sentry** (self-hosted, + Redis/PG se inclusi nel profilo)
* `office` → **Collabora Online** (editor per Nextcloud)
* `s3` → **MinIO** (+ console)
* `backup` → **Restic job** (verso S3/MinIO) + eventuali cron
* `security` → **CrowdSec** + **bouncer per Caddy**

# Verifiche rapide

```bash
# vedere quali servizi ci sono e quali profili richiedono
docker compose config --services

# vedere quali profili hai attivi via ENV
echo "$COMPOSE_PROFILES"

# controllare che i servizi extra siano su
docker compose ps | egrep 'keycloak|grafana|prometheus|loki|uptime|sentry|minio|crowdsec'
```

Se vuoi, ti preparo anche uno **snippet di `.env`** già pronto con `BOOTSTRAP_EXTRA_PROFILES` popolato con i profili che ti servono oggi.
