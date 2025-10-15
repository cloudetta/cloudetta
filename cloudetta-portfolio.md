---
layout: portfolio
title: "Cloudetta"
date: 2025-10-15
description: "Cloudetta è un ecosistema digitale open-source e sovrano per PMI. Integra ERP, marketing, BI, e collaborazione in uno stack Docker unificato, per un controllo totale dei dati e dei processi aziendali."
image: "/assets/images/portfolio/cloudetta/cloudetta.jpg"
image-header: "/assets/images/portfolio/cloudetta/cloudetta.jpg"
image-paint: "/assets/images/portfolio/cloudetta/cloudetta.jpg"
tags: [Open Source, DevOps, Cloud, Docker, Odoo, Django, Mautic, Apache Superset, Business Intelligence, n8n, Prometheus, Grafana, Loki, CrowdSec, Restic, System Architecture, SaaS, Mermaid]
---

> "L'obiettivo di Cloudetta non è fornire software, ma restituire sovranità. È un ecosistema digitale integrato, open-source e self-hosted, che permette alle aziende di possedere e controllare i propri strumenti e i propri dati, liberandosi dal vendor lock-in."

---

## La Visione: Un Ecosistema Digitale Unificato

Cloudetta nasce per risolvere la frammentazione che affligge le PMI: decine di servizi cloud disconnessi, costi mensili crescenti e dati aziendali sparsi presso terzi. La piattaforma aggrega i migliori strumenti open-source in un unico **stack coerente e pre-integrato**, orchestrato da Docker e installabile su qualsiasi infrastruttura (cloud, on-premise, VPS).

Il risultato è un ambiente di lavoro centralizzato, dove i processi fluiscono senza interruzioni tra i vari reparti, dall'ERP al marketing, dalla collaborazione alla business intelligence.

---

## Diagramma Architetturale Interattivo

Questo diagramma mostra come i vari componenti di Cloudetta interagiscono tra loro, dal gateway di ingresso fino ai servizi di backend e agli stack operativi.

```mermaid
graph TD
    subgraph Utente
        Client[Browser / Client API]
    end

    subgraph "Gateway & Sicurezza"
        Caddy(Caddy Reverse Proxy)
        CrowdSec(CrowdSec IPS)
    end

    subgraph "Applicazioni Core"
        Django(Django + Stripe)
        Odoo(Odoo ERP)
        Mautic(Mautic)
        Mattermost(Mattermost)
        Nextcloud(Nextcloud)
        Redmine(Redmine)
        DokuWiki(DokuWiki)
    end

    subgraph "Business Intelligence & Analytics"
        Superset(Apache Superset)
        Analytics(Analytics Cookieless)
    end
    
    subgraph "Automazione"
        N8N(n8n Workflow)
    end

    subgraph "Database"
        PostgresOdoo[(PostgreSQL - Odoo)]
        PostgresDjango[(PostgreSQL - Django)]
        PostgresMattermost[(PostgreSQL - Mattermost)]
        MariaDBNextcloud[(MariaDB - Nextcloud)]
        MariaDBMautic[(MariaDB - Mautic)]
        MariaDBRedmine[(MariaDB - Redmine)]
    end

    subgraph "Stack di Osservabilità"
        Grafana(Grafana)
        Prometheus(Prometheus)
        Loki(Loki)
        Promtail(Promtail)
    end

    subgraph "Backup & Storage"
        Restic(Restic Backup)
        MinIO(MinIO S3 Storage)
    end

    %% Connessioni Principali
    Client --> Caddy
    Caddy --> Django
    Caddy --> Odoo
    Caddy --> Mautic
    Caddy --> Mattermost
    Caddy --> Nextcloud
    Caddy --> Redmine
    Caddy --> DokuWiki
    Caddy --> Superset
    Caddy --> Grafana
    Caddy --> Analytics

    %% Connessioni Database
    Django --> PostgresDjango
    Odoo --> PostgresOdoo
    Mattermost --> PostgresMattermost
    Nextcloud --> MariaDBNextcloud
    Mautic --> MariaDBMautic
    Redmine --> MariaDBRedmine
    Superset --> PostgresOdoo
    Superset --> PostgresDjango
    Superset --> MariaDBMautic

    %% Connessioni Automazione (n8n)
    N8N -.-> Django
    N8N -.-> Odoo
    N8N -.-> Mautic
    N8N -.-> Mattermost
    N8N -.-> Nextcloud
    N8N -.-> Redmine
    
    %% Connessioni Operative (Logging, Monitoring, Sicurezza, Backup)
    Caddy -- Log --> CrowdSec
    Caddy -- Log --> Promtail
    Promtail -- Log --> Loki
    Loki --> Grafana
    Prometheus --> Grafana
    Django -- Metriche & Log --> Prometheus & Promtail
    Odoo -- Metriche & Log --> Prometheus & Promtail
    Restic -- Backup dei Volumi --> MinIO
    
end
```

<!-- Caricamento di Mermaid.js e inizializzazione solo per questa pagina -->
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({ startOnLoad: true });
</script>

---

## I Componenti: Una Suite Aziendale Completa

Cloudetta è modulare. Ogni strumento è un container indipendente ma interconnesso, raggruppato per aree funzionali.

### 1. Gestione e Operatività
Il nucleo che governa l'azienda.
- **Odoo (ERP):** La colonna vertebrale gestionale. Unisce CRM, vendite, acquisti, magazzino, contabilità e fatturazione elettronica italiana (l10n_it, l10n_it_edi).
- **Django + Stripe (SaaS & Billing):** Il motore per la creazione di servizi SaaS, gestisce utenti, abbonamenti, pagamenti e fornisce API sicure per l'integrazione.

### 2. Marketing e Comunicazione
Strumenti per acquisire clienti e facilitare la collaborazione interna.
- **Mautic (Marketing Automation):** Piattaforma per la gestione di campagne email, lead nurturing, segmentazione del pubblico e landing page.
- **Mattermost (Team Chat):** L'alternativa open-source a Slack. Canali di discussione, team, integrazioni e notifiche centralizzate per una comunicazione interna fluida.

### 3. Produttività e Collaborazione
L'ufficio digitale dove il lavoro viene svolto e documentato.
- **Nextcloud (File Sharing):** Archiviazione, condivisione e sincronizzazione sicura dei file aziendali, con client desktop e mobile.
- **Redmine (Project Management):** Strumento robusto per il tracciamento di ticket, la gestione di progetti complessi e il monitoraggio delle attività.
- **DokuWiki (Knowledge Base):** Un wiki semplice e potente per costruire la base di conoscenza interna, documentare procedure e manuali.

### 4. Analisi e Decisioni Strategiche
Trasformare i dati grezzi in insight per guidare le scelte aziendali.
- **Apache Superset (Business Intelligence):** Il cruscotto di BI che si connette ai database di Odoo, Django e Mautic. Permette di creare dashboard interattive per visualizzare KPI di vendita, metriche di marketing e andamento degli abbonamenti.
- **Plausible / Umami (Web Analytics):** Una soluzione di analytics cookieless e rispettosa della privacy per monitorare il traffico e l'utilizzo delle applicazioni web (es. portale Django, sito Odoo) senza compromettere i dati degli utenti.

---

## Il Sistema Nervoso: n8n per l'Automazione dei Workflow

**n8n** è il collante che trasforma questa collezione di strumenti in un vero ecosistema. Attraverso i suoi workflow visuali, automatizza i processi che attraversano più applicazioni.

**Esempi di flussi di lavoro integrati:**
- **Onboarding Cliente Automatizzato:** Un nuovo ordine in **Odoo** scatena un workflow in **n8n** che:
  1. Aggiunge il cliente a una campagna di benvenuto su **Mautic**.
  2. Crea un task di "kick-off" su **Redmine** per il project manager.
  3. Invia una notifica al team vendite su un canale **Mattermost** dedicato.
  4. Crea una cartella cliente condivisa su **Nextcloud**.
- **Sincronizzazione Dati:** I dati dei clienti vengono mantenuti allineati tra **Odoo** e **Django**.
- **Notifiche Intelligenti:** Eventi critici (es. un pagamento fallito su Stripe) generano ticket automatici su **Redmine** e allerte su **Mattermost**.

---

## Architettura e Fondamenta DevOps

Cloudetta è costruita su principi DevOps per garantire stabilità, sicurezza e manutenibilità.

- **Gateway e Sicurezza Perimetrale:**
  - **Caddy Server:** Reverse proxy automatico che gestisce tutto il traffico in entrata, fornisce certificati SSL/TLS e instrada le richieste ai servizi corretti.
  - **CrowdSec:** Sistema di prevenzione delle intrusioni (IPS) che analizza i log di Caddy per identificare e bloccare traffico malevolo in tempo reale.

- **Stack di Osservabilità (Monitoring & Logging):**
  - **Prometheus & Grafana:** Monitoraggio proattivo delle performance di ogni container, dell'uso di CPU/RAM e dello stato dell'infrastruttura. Dashboard preconfigurate in Grafana offrono una vista completa sulla salute del sistema.
  - **Loki & Promtail:** Sistema di logging centralizzato. Tutti i log dei container vengono raccolti, indicizzati e resi ricercabili tramite Grafana, semplificando il troubleshooting.

- **Data Integrity e Disaster Recovery:**
  - **Restic & MinIO:** Soluzione di backup robusta. Restic esegue backup crittografati, deduplicati e incrementali di tutti i volumi Docker e li archivia su uno storage S3-compatibile fornito da MinIO, garantendo restore rapidi e sicuri.
  - **Trivy:** Scanner di vulnerabilità che analizza periodicamente le immagini Docker in uso per identificare falle di sicurezza note, permettendo un hardening proattivo.

---

## Tabella Tecnologica Completa

| Ambito | Strumento | Tecnologia | Ruolo Principale |
|---|---|---|---|
| **Gateway** | Caddy | Go | Reverse Proxy, SSL automatico, Routing |
| **ERP & CRM** | Odoo | Python, PostgreSQL | Gestione aziendale, Fatturazione Elettronica |
| **SaaS & Billing** | Django | Python, PostgreSQL | Gestione abbonamenti, API, pagamenti Stripe |
| **Marketing** | Mautic | PHP, MariaDB | Marketing Automation, Campagne Email |
| **Team Chat** | Mattermost | Go, React, PostgreSQL | Comunicazione interna, Notifiche |
| **File Storage** | Nextcloud | PHP, MariaDB | Archiviazione e condivisione file |
| **Project Mgmt** | Redmine | Ruby on Rails, MariaDB | Ticketing, Gestione progetti |
| **Knowledge Base**| DokuWiki | PHP | Documentazione interna, Wiki |
| **Automazione** | n8n | Node.js, Vue.js | Orchestrazione workflow tra servizi |
| **Business Intel.**| Apache Superset | Python, React | Creazione dashboard e analisi dati |
| **Web Analytics** | Plausible/Umami | Go/Node.js | Statistiche d'uso cookieless |
| **Monitoring** | Prometheus, Grafana | Go, TypeScript | Raccolta metriche e visualizzazione |
| **Logging** | Loki, Promtail | Go | Aggregazione e ricerca log |
| **Backup** | Restic, MinIO | Go | Backup crittografati su storage S3 |
| **Sicurezza** | CrowdSec, Trivy | Go | Intrusion Prevention, Scansione vulnerabilità |
| **Orchestrazione**| Docker Compose | YAML | Definizione e gestione dello stack |

---

## Competenze Dimostrate

Lo sviluppo di Cloudetta dimostra una competenza profonda e trasversale in:

- **System Architecture & DevOps:** Progettazione di architetture a microservizi complesse, containerizzate e resilienti.
- **Full-Stack Development:** Padronanza di ecosistemi diversi (Python/Django, PHP, Ruby, Go, Node.js).
- **Integrazione di Sistemi:** Capacità di far dialogare applicativi eterogenei tramite API, webhook e middleware di automazione (n8n).
- **Cloud & Infrastructure Management:** Gestione di stack Docker, networking, storage persistente e sicurezza perimetrale.
- **Osservabilità e Affidabilità (SRE):** Implementazione di stack completi per monitoring, logging e alerting (Prometheus, Grafana, Loki).
- **Sicurezza Informatica:** Hardening di sistemi, gestione degli accessi, backup e disaster recovery (Caddy, CrowdSec, Restic).
- **Business Process Analysis:** Comprensione dei flussi aziendali per tradurli in soluzioni tecniche integrate (ERP, CRM, Marketing).

---

## Risorse

- **Repository GitHub:** [github.com/cloudetta/cloudetta](https://github.com/cloudetta/cloudetta)
- **Licenza:** MIT © 2025 Antonio Trento