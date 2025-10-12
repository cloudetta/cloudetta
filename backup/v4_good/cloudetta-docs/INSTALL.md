# INSTALL — Cloudetta
**by Antonio Trento — https://antoniotrento.net**

> Docker Compose, domini `*.example.com` e `*.localhost`, compatibile con Cloudflare Tunnel.

---

## 🇮🇹 Installazione
1. **Prerequisiti**
   - Docker + Docker Compose
   - DNS per: `django/odoo/redmine/wiki/nextcloud/n8n.example.com` (o usa `*.localhost`)
2. **Clona e prepara**
   ```bash
   cp .env.example .env
   # compila le password/chiavi (Stripe, DB, Mail)
   chmod +x install.sh && ./install.sh
   ```
3. **Workflow**
   ```bash
   ./integration/setup_api_links.sh
   ```
4. **Accesso servizi**
   - Django: `https://django.example.com` (o `http://django.localhost`)
   - Odoo: `https://odoo.example.com`
   - Nextcloud: `https://nextcloud.example.com`
   - Redmine: `https://redmine.example.com`
   - DokuWiki: `https://wiki.example.com`
   - n8n: `https://n8n.example.com`

### Cloudflare Tunnel (opzione)
Esegui un tunnel che punti a `caddy:80/443` e mappa i sottodomini alle route.

---

## 🇬🇧 Installation
1. **Requirements**
   - Docker + Docker Compose
   - DNS for: `django/odoo/redmine/wiki/nextcloud/n8n.example.com` (or use `*.localhost`)
2. **Clone & prepare**
   ```bash
   cp .env.example .env
   # fill secrets/keys (Stripe, DB, Mail)
   chmod +x install.sh && ./install.sh
   ```
3. **Workflows**
   ```bash
   ./integration/setup_api_links.sh
   ```
4. **Service URLs**
   - Django: `https://django.example.com` (or `http://django.localhost`)
   - Odoo: `https://odoo.example.com`
   - Nextcloud: `https://nextcloud.example.com`
   - Redmine: `https://redmine.example.com`
   - DokuWiki: `https://wiki.example.com`
   - n8n: `https://n8n.example.com`

### Cloudflare Tunnel (option)
Run a tunnel to `caddy:80/443` and map subdomains to routes.
