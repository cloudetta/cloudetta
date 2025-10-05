# CONFIGURATION — Cloudetta

## 🇮🇹 Configurazione
- **.env**: imposta password DB, `DJANGO_SECRET_KEY`, `STRIPE_SECRET_KEY`, `MAIL_*`.
- **Caddy**: modifica `caddy/Caddyfile` con i tuoi domini.
- **Odoo**: attiva moduli `l10n_it`, `l10n_it_edi`; configura azienda, PEC, SDI.
- **Mail**: `MAIL_PROVIDER=sendgrid|mailcow|smtp` + credenziali.

## 🇬🇧 Configuration
- **.env**: set DB passwords, `DJANGO_SECRET_KEY`, `STRIPE_SECRET_KEY`, `MAIL_*`.
- **Caddy**: edit `caddy/Caddyfile` with your domains.
- **Odoo**: enable `l10n_it`, `l10n_it_edi`; configure company, PEC, SDI.
- **Mail**: `MAIL_PROVIDER=sendgrid|mailcow|smtp` + credentials.
