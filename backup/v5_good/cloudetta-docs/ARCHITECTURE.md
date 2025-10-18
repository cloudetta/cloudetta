# ARCHITECTURE — Cloudetta

## 🇮🇹 Architettura (Mermaid)
```mermaid
flowchart LR
  subgraph Proxy
    Caddy[Caddy Reverse Proxy]
  end

  subgraph Core
    Django[Django (Stripe, API)]
    Odoo[Odoo (l10n_it, l10n_it_edi)]
    Nextcloud[Nextcloud]
    Redmine[Redmine]
    DokuWiki[DokuWiki]
    n8n[n8n Orchestrator]
  end

  subgraph Data
    PGD[(Postgres Django)]
    PGO[(Postgres Odoo)]
    MR[(MariaDB Redmine)]
    MN[(MariaDB Nextcloud)]
    Vols[(Volumes/Backups)]
  end

  Client((Browser/Apps)) --> Caddy
  Caddy --> Django
  Caddy --> Odoo
  Caddy --> Nextcloud
  Caddy --> Redmine
  Caddy --> DokuWiki
  Caddy --> n8n

  Django --- n8n
  n8n --- Odoo
  n8n --- Nextcloud
  n8n --- Redmine

  Django --- PGD
  Odoo --- PGO
  Redmine --- MR
  Nextcloud --- MN

  Vols --- Django
  Vols --- Odoo
  Vols --- Nextcloud
  Vols --- Redmine
  Vols --- n8n
```

## 🇬🇧 Architecture (Mermaid)
*(same diagram as above; Mermaid renders in Markdown viewers that support it)*
