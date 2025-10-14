#manca apache superset da inerire


grandissimo — ti propongo un’estensione “pulita” del tuo stack usando **profili Compose** dedicati, così puoi accendere/spegnere i blocchi a piacere:

* `sso` → Keycloak (+ Postgres dedicato)
* `monitoring` → Prometheus + node-exporter + cAdvisor + Alertmanager + Grafana
* `logging` → Loki + Promtail
* `uptime` → Uptime-Kuma
* `errors` → Sentry *oppure* (più leggero) GlitchTip
* `backup` → MinIO (S3-compat) + Restic job schedulato
* `office` → Collabora Online (Nextcloud)
* `security` → CrowdSec + **Caddy bouncer** (Caddy custom con plugin)
* `vulnscan` → Trivy (cron) + report su volume

Di seguito **architettura**, **scelte** e **snippet pronti** (minimal ma funzionanti) da aggiungere al tuo `docker-compose.yml` mantenendo lo stile/profili attuali. Se vuoi, nel prossimo giro ti genero i file completi `.env`, `compose` e provisioning auto-wiring.

---

# Linee guida d’integrazione

* Tutto resta su **rete `internal`** (come ora). Le UI che devono uscire (Grafana, Uptime-Kuma, GlitchTip/Sentry, Keycloak, Collabora) le **pubblichi via Caddy** in `prod` e su `*.localhost` in `local`.
* Ogni blocco ha **volume dedicato** e **healthcheck**.
* Aggiungo poche variabili in `.env` (prefisso per blocco) così eviti hard-coding.

---

# Variabili da aggiungere a `.env`

```env
# ==== SSO (Keycloak) ====
KEYCLOAK_DOMAIN=                 # es. sso.example.com (solo prod)
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=ChangeMe!123
KEYCLOAK_DB_PASSWORD=kc_db_pw

# ==== Monitoring ====
GRAFANA_DOMAIN=                  # es. grafana.example.com (prod)
PROM_ADMIN_USER=promadmin
PROM_ADMIN_PASS=ChangeMe!123

# ==== Logging ====
LOKI_DOMAIN=
# promtail: path docker (linux)
DOCKER_LOG_DIR=/var/lib/docker/containers

# ==== Uptime ====
UPTIMEKUMA_DOMAIN=

# ==== Error tracking ====
# Scegli UNO: Sentry (pesante) o GlitchTip (leggero)
ERRORS_DOMAIN=
ERRORS_CHOICE=glitchtip          # glitchtip | sentry
GLITCHTIP_SECRET_KEY=dev_secret_glitch
GLITCHTIP_DB_PASSWORD=gt_db_pw
SENTRY_SECRET_KEY=dev_secret_sentry

# ==== Backup (S3) ====
MINIO_DOMAIN=
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=miniochange
RESTIC_REPO=s3:http://minio:9000/cloudetta-backups
RESTIC_PASSWORD=restic_change
RESTIC_ACCESS_KEY_ID=${MINIO_ROOT_USER}
RESTIC_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD}

# ==== Office ====
COLLABORA_DOMAIN=

# ==== Security (CrowdSec + Caddy bouncer) ====
CROWDSEC_DOMAIN=
```

---

# Snippet Compose per profili

## 1) SSO – Keycloak (`profile: sso`)

```yaml
  keycloak-db:
    image: postgres:15
    profiles: ["sso"]
    environment:
      POSTGRES_DB=keycloak
      POSTGRES_USER=keycloak
      POSTGRES_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
    volumes: [ keycloak_db:/var/lib/postgresql/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U keycloak -h 127.0.0.1 -d keycloak"]
      interval: 10s; timeout: 5s; retries: 10

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    profiles: ["sso"]
    command: ["start","--http-enabled=true","--hostname-url","http://keycloak.localhost"]  # in prod metti https://${KEYCLOAK_DOMAIN}
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
      interval: 20s; timeout: 5s; retries: 15
```

> In Caddy `local`: `http://keycloak.localhost { reverse_proxy keycloak:8080 }`
> In `prod`: `https://${KEYCLOAK_DOMAIN} { import security_preset; reverse_proxy keycloak:8080 }`

---

## 2) Monitoring – Prometheus stack (`profile: monitoring`)

```yaml
  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.8.2
    profiles: ["monitoring"]
    pid: host
    network_mode: host
    command: [ "--path.rootfs=/host" ]
    volumes: [ "/:/host:ro,rslave" ]
    healthcheck: { test: ["CMD","wget","-qO-","http://127.0.0.1:9100/metrics"], interval: 30s, timeout: 5s, retries: 10 }

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.2
    profiles: ["monitoring"]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks: [ internal ]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:8080/metrics"], interval: 30s, timeout: 5s, retries: 10 }

  prometheus:
    image: prom/prometheus:v2.54.1
    profiles: ["monitoring"]
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom_data:/prometheus
    networks: [ internal ]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:9090/-/ready"], interval: 20s, timeout: 5s, retries: 10 }

  alertmanager:
    image: prom/alertmanager:v0.27.0
    profiles: ["monitoring"]
    volumes:
      - ./monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alert_data:/alertmanager
    networks: [ internal ]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:9093/-/ready"], interval: 20s, timeout: 5s, retries: 10 }

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
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:3000/robots.txt"], interval: 20s, timeout: 5s, retries: 10 }
```

Prometheus config minimale (`monitoring/prometheus.yml`) che scrapa `cadvisor`, `node-exporter`, Caddy e le tue app (puoi esporre metrics su Django/others se disponibili).

---

## 3) Logging – Loki + Promtail (`profile: logging`)

```yaml
  loki:
    image: grafana/loki:3.1.1
    profiles: ["logging"]
    command: ["-config.file=/etc/loki/config.yml"]
    volumes:
      - ./logging/loki-config.yml:/etc/loki/config.yml:ro
      - loki_data:/loki
    networks: [ internal ]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:3100/ready"], interval: 20s, timeout: 5s, retries: 10 }

  promtail:
    image: grafana/promtail:3.1.1
    profiles: ["logging"]
    volumes:
      - ./logging/promtail-config.yml:/etc/promtail/config.yml:ro
      - ${DOCKER_LOG_DIR}:/var/lib/docker/containers:ro
      - /var/log:/var/log:ro
    command: ["--config.file=/etc/promtail/config.yml"]
    networks: [ internal ]
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:9080/ready"], interval: 20s, timeout: 5s, retries: 10 }
```

> In Grafana aggiungi **Loki** come datasource e usa il dashboard “Docker logs”.

---

## 4) Uptime-Kuma (`profile: uptime`)

```yaml
  uptime-kuma:
    image: louislam/uptime-kuma:1.23.16
    profiles: ["uptime"]
    volumes: [ uptimekuma_data:/app/data ]
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:3001 || exit 1"]
      interval: 20s; timeout: 5s; retries: 10
```

---

## 5) Error tracking – **GlitchTip** (consigliato) *oppure* Sentry (`profile: errors`)

**GlitchTip (leggero):**

```yaml
  glitchtip-db:
    image: postgres:15
    profiles: ["errors"]
    environment:
      POSTGRES_DB=glitchtip
      POSTGRES_USER=glitchtip
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
      interval: 20s; timeout: 5s; retries: 10
```

> In Django installi l’SDK Sentry-compat (GlitchTip parla lo stesso protocollo).

*(Se vuoi proprio Sentry self-hosted: consiglierei stack dedicato ufficiale, è molto pesante: Kafka, ClickHouse, Redis, Zookeeper… Posso fornirti un compose separato).*

---

## 6) Backup – MinIO + Restic cron (`profile: backup`)

```yaml
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
      interval: 20s; timeout: 5s; retries: 10

  restic-cron:
    image: alpine:3.20
    profiles: ["backup"]
    environment:
      RESTIC_REPOSITORY: ${RESTIC_REPO}
      RESTIC_PASSWORD: ${RESTIC_PASSWORD}
      AWS_ACCESS_KEY_ID: ${RESTIC_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${RESTIC_SECRET_ACCESS_KEY}
    volumes:
      - /var/lib/docker/volumes:/vols:ro     # snapshot “a freddo” delle dir dei volumi
      - ./backups/restic:/restic             # log/report
    entrypoint: ["/bin/sh","-lc","apk add --no-cache restic curl tzdata; echo '0 3 * * * /usr/bin/restic backup /vols --tag cloudetta >> /restic/backup.log 2>&1' | crontab - && crond -f"]
    networks: [ internal ]
```

> Per backup applicativi “coerenti” continua a usare i tuoi dump DB + tar volumi (già presenti) **e** archiviali in Restic (offsite).

---

## 7) Office – Collabora (Nextcloud) (`profile: office`)

```yaml
  collabora:
    image: collabora/code:24.04.10.1.1
    profiles: ["office"]
    environment:
      extra_params: --o:ssl.enable=false  # in prod metti true dietro Caddy
      username: ${ADMIN_USER}
      password: ${ADMIN_PASS}
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://localhost:9980 | grep -q 'OK' || exit 1"]
      interval: 30s; timeout: 5s; retries: 10
```

> In Nextcloud: app **Richdocuments**, imposta WOPI server a `http://collabora:9980` (local) o il dominio via Caddy in prod.

---

## 8) Security – CrowdSec + **Caddy bouncer** (`profile: security`)

Per usare il **bouncer Caddy** serve un’immagine Caddy costruita con il plugin. Ti propongo un servizio Caddy **custom** solo per prod:

**Dockerfile (`caddy/Dockerfile.crowdsec`)**

```dockerfile
FROM caddy:2.8.4-builder AS builder
RUN xcaddy build \
  --with github.com/crowdsecurity/caddy-bouncer/v2

FROM caddy:2.8.4
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile.prod.tmpl /etc/caddy/Caddyfile.prod.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
```

**Compose:**

```yaml
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    profiles: ["security"]
    volumes:
      - crowdsec_data:/var/lib/crowdsec/data
      - /var/log:/var/log:ro
    networks: [ internal ]
    healthcheck:
      test: ["CMD-SHELL","cscli metrics >/dev/null 2>&1 || exit 1"]
      interval: 30s; timeout: 5s; retries: 10

  caddy-prod:
    build:
      context: ./caddy
      dockerfile: Dockerfile.crowdsec
    profiles: ["security","prod"]  # si attiva con entrambi
    # (il resto è uguale al tuo caddy-prod: volumi, porte, env)
```

Nel tuo `Caddyfile.prod.tmpl` aggiungi (dentro `security_preset` o per-vhost):

```
@crowdsec {
  crowdsec
}
route {
  crowdsec
  reverse_proxy app:port
}
```

*(Se preferisci non buildare Caddy: alternativa è usare **traefik-bouncer** davanti a Caddy, ma complica.)*

---

## 9) Vulnerability scan – Trivy (`profile: vulnscan`)

```yaml
  trivy-cron:
    image: aquasec/trivy:0.55.0
    profiles: ["vulnscan"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./security/trivy:/reports
    entrypoint: ["/bin/sh","-lc","echo '30 4 * * * trivy image --severity HIGH,CRITICAL --format table --output /reports/images_$(date +\\%F).txt $(docker images --format {{.Repository}}:{{.Tag}} | tr '\\n' ' ')' | crontab - && crond -f"]
    networks: [ internal ]
```

---

# Caddy (routing local/prod)

Aggiungi i vhost alle due varianti:

**`caddy/Caddyfile.local`** (esempi):

```
http://keycloak.localhost { reverse_proxy keycloak:8080 }
http://grafana.localhost { reverse_proxy grafana:3000 }
http://logs.localhost    { reverse_proxy loki:3100 }
http://uptime.localhost  { reverse_proxy uptime-kuma:3001 }
http://errors.localhost  { reverse_proxy glitchtip:8000 }   # o sentry-web:9000
http://s3.localhost      { reverse_proxy minio:9001 }
http://office.localhost  { reverse_proxy collabora:9980 }
```

**`Caddyfile.prod.tmpl`** (esempi):

```
${KEYCLOAK_DOMAIN:+https://${KEYCLOAK_DOMAIN} { import security_preset; reverse_proxy keycloak:8080 }}
${GRAFANA_DOMAIN:+https://${GRAFANA_DOMAIN} { import security_preset; reverse_proxy grafana:3000 }}
${LOKI_DOMAIN:+https://${LOKI_DOMAIN} { import security_preset; reverse_proxy loki:3100 }}
${UPTIMEKUMA_DOMAIN:+https://${UPTIMEKUMA_DOMAIN} { import security_preset; reverse_proxy uptime-kuma:3001 }}
${ERRORS_DOMAIN:+https://${ERRORS_DOMAIN} { import security_preset; reverse_proxy glitchtip:8000 }}
${MINIO_DOMAIN:+https://${MINIO_DOMAIN} { import security_preset; reverse_proxy minio:9001 }}
${COLLABORA_DOMAIN:+https://${COLLABORA_DOMAIN} { import security_preset; reverse_proxy collabora:9980 }}
```

---

# Come accendere i blocchi

* **SSO + Monitoring + Logging + Uptime (local):**

  ```bash
  docker compose --profile local --profile sso --profile monitoring --profile logging --profile uptime up -d
  ```

* **Prod completo (escluso Sentry pesante):**

  ```bash
  docker compose --profile prod --profile sso --profile monitoring --profile logging --profile uptime --profile backup --profile office --profile security --profile vulnscan up -d
  ```

---

## Perché così?

* **Isolamento per profili**: puoi iterare/aggiornare un “blocco” alla volta (observability, sso…) senza toccare il core.
* **SSO davanti a tutto**: riduci gestione credenziali; OIDC è supportato da tutte le tue app.
* **Observability e Logging separati**: Prometheus/Grafana per *metriche*; Loki/Promtail per *log* → due viste complementari.
* **Backup offsite**: Restic+MinIO ti dà retention/versioning e deduplica; rimane compatibile con i tuoi dump attuali.
* **Security**: CrowdSec + bouncer su Caddy = protezione 80/443 centralizzata (rate-limit, reputation).
* **Scans periodiche**: Trivy su immagini ti evita CVE silenziose.

---

Se vuoi, ti preparo i **file completi** (cartelle `monitoring/`, `logging/`, `security/`, provisioning Grafana con datasource Prometheus+Loki, `prometheus.yml` basico, `promtail-config.yml`, `alertmanager.yml`, ecc.) già con **pin versione** e **healthcheck**, così fai copia-incolla e parte tutto.





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

* **Local con add-ons base (sso+monitoring+logging+uptime):**

```bash
./bootstrap_cloudetta.sh   # auto "local"
docker compose --profile sso --profile monitoring --profile logging --profile uptime up -d
```

* **Prod completo (quando imposti i domini nello .env):**

```bash
BOOTSTRAP_PROFILES=prod ./bootstrap_cloudetta.sh
docker compose --profile sso --profile monitoring --profile logging --profile uptime --profile errors --profile backup --profile office --profile security --profile vulnscan up -d
```

---

Se vuoi, nel prossimo messaggio posso aggiungere:

* **snippet OIDC** per Django/Nextcloud/Redmine/Mattermost/Mautic (redirect URI e claim),
* un paio di **dashboard Grafana** pre-provisionate (Docker/Host),
* **webhook Alertmanager→Mattermost** di esempio.
