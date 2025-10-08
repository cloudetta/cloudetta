Perfetto — ora che “si vede tutto”, mettiamo **le stesse credenziali admin** ovunque, sistemiamo **Nextcloud trusted_domains**, e **mettiamo in sicurezza Odoo** (master password + DB creato). Ti lascio sia i **comandi immediati** (da copiare/incollare ora) sia le **patch** da tenere in bootstrap/compose per averlo già pronto sia in locale che online.

---

# 1) Unifica le credenziali (una volta sola in `.env`)

Aggiungi/aggiorna queste chiavi nel tuo `.env`:

```env
# credenziali amministratore unificate
ADMIN_USER=admin
ADMIN_PASS=ChangeMe!123
ADMIN_EMAIL=admin@example.com

# odoo
ODOO_DB=cloudetta
ODOO_MASTER_PASSWORD=${ADMIN_PASS}       # o un valore diverso se preferisci
ODOO_LANG=it_IT
ODOO_DEMO=false                          # true/false

# domini (locale+prod)
PUBLIC_DOMAIN=example.tld                # metti il dominio prod, se c’è
TRUSTED_DOMAINS=localhost,127.0.0.1,nextcloud, \
nextcloud.localhost,${PUBLIC_DOMAIN}
```

> Nota: il bootstrap che ti ho dato già usa `DJANGO_ADMIN_*`, `NEXTCLOUD_ADMIN_*`, `N8N_*`. Con le variabili sopra, nei passi sotto le usiamo per allineare **Redmine, Nextcloud, n8n, Odoo e Wiki**.

---

# 2) Login: cosa usare adesso (stato attuale)

* **Django**: `http://django.localhost/admin/` → **${DJANGO_ADMIN_USER}/${DJANGO_ADMIN_PASS}**
  (dai log: creato correttamente)
* **Nextcloud**: dopo fix trusted_domains (punto 3), admin sarà **${NEXTCLOUD_ADMIN_USER}/${NEXTCLOUD_ADMIN_PASS}**
  (se bootstrap ha appena “installato”, li ha già impostati)
* **Redmine**: di default è `admin/admin` → sotto ti do il comando per **uniformarlo a ${ADMIN_PASS}**
* **n8n**: se vuoi bloccarlo con basic auth: **${ADMIN_USER}/${ADMIN_PASS}** (vedi punto 5)
* **Odoo**: creeremo **master password** = `${ODOO_MASTER_PASSWORD}` e **DB** `${ODOO_DB}` con admin = **${ADMIN_EMAIL}/${ADMIN_PASS}**
* **DokuWiki**: per semplificare e non dipendere dall’immagine, ti propongo **Basic Auth su Caddy** con **${ADMIN_USER}/${ADMIN_PASS}** (punto 6)

---

# 3) Nextcloud – “dominio non attendibile”

Sistema **trusted_domains** (subito) e l’URL canonico per prod (se ce l’hai):

```bash
# elenca (debug)
docker compose exec -T nextcloud bash -lc 'occ config:system:get trusted_domains || true'

# AZZERA e reimposta from scratch (0..N). È idempotente.
docker compose exec -T nextcloud bash -lc '
set -e
idx=0
for d in ${TRUSTED_DOMAINS//,/ }; do
  occ config:system:set trusted_domains '"$idx"' --value "$d"
  idx=$((idx+1))
done
# opzionale: URL canonico per CLI/cron (se hai dominio prod)
if [ -n "${PUBLIC_DOMAIN:-}" ]; then
  occ config:system:set overwrite.cli.url --value "https://${PUBLIC_DOMAIN}"
fi
'
```

Dopo questo apre bene:

* locale: `http://nextcloud.localhost`
* prod: `https://$PUBLIC_DOMAIN` (Caddy farà TLS auto)

> Se preferisci incorporarlo nel **bootstrap**, metti quelle 8 righe dopo il blocco “Nextcloud install/config”.

---

# 4) Redmine – imposta password/email admin unificate

Porta l’utente `admin` alla stessa password/email dell’admin “globale”:

```bash
docker compose exec -T \
  -e ADMIN_PASS="$ADMIN_PASS" \
  -e ADMIN_EMAIL="$ADMIN_EMAIL" \
  redmine bash -lc '
bundle exec rails runner "
  u = User.find_by_login(\"admin\")
  if u
    u.password = ENV[\"ADMIN_PASS\"]
    u.password_confirmation = ENV[\"ADMIN_PASS\"]
    u.mail = ENV[\"ADMIN_EMAIL\"]
    u.must_change_passwd = false
    u.save!
    puts \"Redmine admin aggiornato: #{u.mail}\"
  else
    puts \"ERRORE: utente admin non trovato\"
  end
"
'
```

> (Puoi mettere questo snippet **dopo** le migrazioni Redmine nel bootstrap, così è già allineato ad ogni deploy.)

---

# 5) n8n – abilita Basic Auth con le credenziali unificate

Nel `docker-compose.yml` del servizio **n8n**, aggiungi:

```yaml
environment:
  - N8N_BASIC_AUTH_ACTIVE=true
  - N8N_BASIC_AUTH_USER=${ADMIN_USER}
  - N8N_BASIC_AUTH_PASSWORD=${ADMIN_PASS}
```

Poi:

```bash
docker compose up -d n8n
```

Ora accedi con **${ADMIN_USER}/${ADMIN_PASS}**.

---

# 6) DokuWiki – proteggilo subito con Basic Auth su Caddy

È la via più robusta e indipendente dall’immagine usata. Genera l’hash bcrypt della tua password:

```bash
docker compose exec -T caddy caddy hash-password --plaintext "$ADMIN_PASS"
# copia il risultato, tipo: $2a$14$........
```

Nel tuo `Caddyfile` (host wiki), aggiungi:

```caddy
wiki.localhost {
  basicauth /* {
    {env.ADMIN_USER} <PASTE_HASH_BCRYPT>
  }
  reverse_proxy dokuwiki:80
}
```

Ricarica:

```bash
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
```

> Vuoi anche login “interno” alla wiki? Possiamo farlo, ma cambia a seconda dell’immagine (alcune supportano env iniziali, altre no). Basic Auth su Caddy è immediata e identica in locale/online.

---

# 7) Odoo – imposta master password e crea il DB automaticamente

### 7.1 Imposta **master password** senza aprire la UI

Scrivi `~/.odoorc` nel container (Odoo la legge automaticamente):

```bash
docker compose exec -T odoo bash -lc '
install -m 600 /dev/stdin /var/lib/odoo/.odoorc <<EOF
[options]
admin_passwd = '"$ODOO_MASTER_PASSWORD"'
EOF
'
docker compose restart odoo
```

### 7.2 Crea il database via HTTP (idempotente)

Se il DB non esiste, creiamolo con i campi che vedi nella pagina di setup:

```bash
# Se risponde 200/302/401/403, Odoo è su
docker run --rm --network cloudetta_internal curlimages/curl -s -o /dev/null -w "%{http_code}\n" http://odoo:8069

# Crea il DB solo se non esiste già
docker run --rm --network cloudetta_internal curlimages/curl -s -X POST \
  http://odoo:8069/web/database/create \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "master_pwd=${ODOO_MASTER_PASSWORD}" \
  --data-urlencode "name=${ODOO_DB}" \
  --data-urlencode "lang=${ODOO_LANG:-en_US}" \
  --data-urlencode "login=${ADMIN_EMAIL}" \
  --data-urlencode "password=${ADMIN_PASS}" \
  --data-urlencode "phone=" \
  --data-urlencode "country_code=" \
  --data-urlencode "demo=${ODOO_DEMO}"
```

Dopo: login su `http://odoo.localhost` con **${ADMIN_EMAIL}/${ADMIN_PASS}**.

> Se vuoi, questo blocco si può aggiungere al **bootstrap** dopo il check HTTP di Odoo.

---

# 8) Riassunto URL + login (dopo i passi sopra)

* **Redmine** → `http://redmine.localhost` → **admin / ${ADMIN_PASS}**
* **Nextcloud** → `http://nextcloud.localhost` → **${NEXTCLOUD_ADMIN_USER} / ${NEXTCLOUD_ADMIN_PASS}**
* **n8n** → `http://n8n.localhost` → **${ADMIN_USER} / ${ADMIN_PASS}** (sezione 5)
* **Odoo** → `http://odoo.localhost` → **${ADMIN_EMAIL} / ${ADMIN_PASS}** (db `${ODOO_DB}`)
* **Django admin** → `http://django.localhost/admin/` → **${DJANGO_ADMIN_USER} / ${DJANGO_ADMIN_PASS}**
* **DokuWiki** → `http://wiki.localhost` → **Basic Auth ${ADMIN_USER} / ${ADMIN_PASS}** (sezione 6)

In produzione:

* Nextcloud e gli altri host saranno `https://<host.tuo.dominio>`.
* Ricordati di includere il dominio prod in `TRUSTED_DOMAINS` (punto 3) e in Caddyfile.

---

Se vuoi, posso darti **le patch pronte** per:

* aggiungere al **bootstrap**: fix `trusted_domains` via `occ`, set password admin Redmine, creazione DB Odoo;
* aggiornare `docker-compose.yml` per **n8n Basic Auth** e lo snippet **Caddyfile** per **wiki**.
