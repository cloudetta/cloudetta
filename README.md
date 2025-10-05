# SaaS Biz Toolkit Stack (Django + Odoo + n8n + Nextcloud + Redmine + DokuWiki)

## Avvio rapido
1) Copia `.env.example` in `.env` e modifica le password/chiavi.
2) `chmod +x install.sh` e `./install.sh`
3) Quando i servizi sono up: `./integration/setup_api_links.sh` per creare i workflow base su n8n.

## Domini
- Localhost: *.localhost (es. http://django.localhost)
- Esempio: *.example.com (configura DNS + Caddy)
- Cloudflare Tunnel: mappa il tuo domain/tunnel verso la porta 80/443 del container caddy

## Backup
- Cron giornaliero h 02:00 nel container `backup`
- Output in `./backups/YYYYmmdd_HHMMSS/`
- Esecuzione manuale: `docker exec -it backup /backup/backup.sh`

## Note
- Questo pacchetto include una **Django app minimale** con endpoint placeholder per ordini/fatture.
- Integra Stripe via variabili d'ambiente (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`).
- Per FatturaPA/SDI attiva in Odoo i moduli `l10n_it` e `l10n_it_edi` e configura la tua azienda.
