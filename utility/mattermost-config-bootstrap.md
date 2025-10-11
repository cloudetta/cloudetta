Sì—non c’è un “utente admin predefinito”, ma puoi **crear(ne) uno automaticamente al primo avvio** con uno script di bootstrap. L’idea è:

1. abiliti il **Local Mode** via variabile d’ambiente (così `mmctl` può operare senza login);
2. avvii Mattermost, attendi che sia pronto, poi esegui `mmctl --local user create ... --system-admin` una sola volta.

Di seguito un esempio minimale con Docker Compose.

### `docker-compose.yml`

```yaml
services:
  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost
    restart: unless-stopped
    ports:
      - "8065:8065"
    environment:
      MM_SERVICESETTINGS_ENABLELOCALMODE: "true"   # abilita Local Mode
      # aggiungi qui le altre MM_* che ti servono (dominio, email di supporto, ecc.)
    volumes:
      - ./mattermost-data:/mattermost/data
      - ./config:/mattermost/config
      - ./logs:/mattermost/logs
      - ./plugins:/mattermost/plugins
      - ./client-plugins:/mattermost/client/plugins
      - ./init-admin.sh:/docker-entrypoint-wait/init-admin.sh:ro
    entrypoint: ["/bin/sh","-c"]
    command: |
      '
      # avvia Mattermost in background
      /entrypoint.sh mattermost &

      # attende il socket locale del Local Mode
      echo "Waiting for local mode socket..."
      for i in $(seq 1 120); do
        [ -S /var/tmp/mattermost_local.socket ] && break
        sleep 1
      done

      # esegue lo script di creazione admin (idempotente)
      /bin/sh /docker-entrypoint-wait/init-admin.sh || true

      # porta il processo in foreground (tiene vivo il container)
      wait -n
      '
```

### `init-admin.sh`

```sh
#!/bin/sh
# Parametri del tuo admin iniziale
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-ChangeMe!123}"

# Se l'utente esiste, esce silenziosamente
if mmctl --local user search "$ADMIN_EMAIL" 2>/dev/null | grep -q "$ADMIN_EMAIL"; then
  echo "Admin già presente, skip."
  exit 0
fi

# Crea l'utente e promuovilo a system admin
mmctl --local user create \
  --email "$ADMIN_EMAIL" \
  --username "$ADMIN_USER" \
  --password "$ADMIN_PASS" \
  --system-admin

echo "Admin creato: $ADMIN_USER <$ADMIN_EMAIL>"
```

> Note:
>
> * Il **Local Mode** si abilita con `MM_SERVICESETTINGS_ENABLELOCALMODE=true`; `mmctl --local` funziona senza credenziali ma solo **sulla stessa macchina/container** del server. ([docs.mattermost.com][1])
> * Il comando per creare l’utente admin è `mmctl user create ... --system-admin`. ([docs.mattermost.com][2])
> * Di default, se non fai nulla, **il primo utente registrato diventa System Admin**. Qui stiamo solo automatizzando quel passo. ([docs.mattermost.com][3])

Se preferisci evitare di sovrascrivere `entrypoint`, alternativa semplice: avvia il container normalmente (con Local Mode attivo) e poi lancia **una volta** da host:

```bash
docker exec mattermost sh -lc '
  mmctl --local user create \
    --email admin@example.com \
    --username admin \
    --password "ChangeMe!123" \
    --system-admin
'
```

Stesso effetto, solo manuale.

[1]: https://docs.mattermost.com/administration-guide/manage/mmctl-command-line-tool.html?utm_source=chatgpt.com "mmctl command line tool"
[2]: https://docs.mattermost.com/administration-guide/configure/user-management-configuration-settings.html?utm_source=chatgpt.com "User management configuration settings"
[3]: https://docs.mattermost.com/end-user-guide/collaborate/learn-about-roles.html?utm_source=chatgpt.com "Learn about Mattermost roles"



Hai ragione a chiedere chiarimenti. Quello “non per produzione” era riferito **alla Docker Preview**, non al **Local Mode**.  
Il **Local Mode** (`mmctl --local`) è una feature ufficiale pensata proprio per automazione/bootstrapping e si può usare in ambienti production **se** lo tieni limitato al container/host e lo **disattivi dopo il bootstrap**. citeturn0search4turn0search0turn0search9

Ecco un modo “production-ready” per avere un System Admin creato automaticamente al montaggio del container:

### Strategia consigliata (one-shot bootstrap, poi harden)
1) **Abilita temporaneamente** il Local Mode via env var:
   - `MM_SERVICESETTINGS_ENABLELOCALMODE=true` (mappato a `ServiceSettings.EnableLocalMode` in `config.json`). citeturn0search3turn0search9  
2) Avvia Mattermost, **attendi il socket locale**, esegui **una volta**:
   ```sh
   mmctl --local user create \
     --email admin@example.com \
     --username admin \
     --password 'UnaPasswordMoltoForte!' \
     --system-admin
   ```
   (È il comando ufficiale per creare l’utente e promuoverlo admin.) citeturn0search0  
3) **Disabilita** il Local Mode (rimuovi l’env var o riportala a `false`) e **riavvia** il servizio. citeturn0search9

### Esempio Docker Compose (idempotente)
```yaml
services:
  mattermost:
    image: mattermost/mattermost-team-edition:latest
    restart: unless-stopped
    ports: ["8065:8065"]
    environment:
      MM_SERVICESETTINGS_ENABLELOCALMODE: "true"  # TEMPORANEO per bootstrap
    volumes:
      - ./data:/mattermost/data
      - ./config:/mattermost/config
      - ./logs:/mattermost/logs
      - ./plugins:/mattermost/plugins
      - ./init-admin.sh:/docker-entrypoint-wait/init-admin.sh:ro
    entrypoint: ["/bin/sh","-c"]
    command: |
      '
      /entrypoint.sh mattermost &

      # attende il socket del Local Mode
      for i in $(seq 1 120); do
        [ -S /var/tmp/mattermost_local.socket ] && break
        sleep 1
      done

      # crea l'admin solo se non esiste
      /bin/sh /docker-entrypoint-wait/init-admin.sh || true

      wait -n
      '
```

`init-admin.sh`:
```sh
#!/bin/sh
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-ChangeMe!123}"

if mmctl --local user search "$ADMIN_EMAIL" 2>/dev/null | grep -q "$ADMIN_EMAIL"; then
  echo "Admin già presente, skip."
  exit 0
fi

mmctl --local user create \
  --email "$ADMIN_EMAIL" \
  --username "$ADMIN_USER" \
  --password "$ADMIN_PASS" \
  --system-admin

echo "Creato admin $ADMIN_USER <$ADMIN_EMAIL>"
```

Dopo il primo avvio riuscito:
- rimuovi/porta a `false` `MM_SERVICESETTINGS_ENABLELOCALMODE` e riavvia (così il socket locale sparisce). citeturn0search9

### Perché è sicuro così?
- **Local Mode** accetta comandi **solo localmente** (stesso host/container) tramite socket Unix; non espone API aggiuntive in rete. Noi lo **teniamo attivo solo per il bootstrap** e poi lo disattiviamo. citeturn0search9
- Il comando `mmctl user create --system-admin` è l’interfaccia supportata per gestire utenti da script. citeturn0search0
- È lo stesso flusso raccomandato dai doc Docker: “crea il tuo primo utente admin” dopo il deploy; qui lo **automatizziamo** in modo ripetibile. citeturn0search4

Se sei su **Kubernetes**, puoi applicare la stessa logica con:
- un **initJob/sidecar** che esegue `mmctl --local` nel pod,  
- quindi rimuovere `ENABLELOCALMODE` dal manifest dopo il bootstrap (o impostarlo via un patch “post-bootstrap”).  
Per il resto, i doc ufficiali raccomandano l’**Operator** per deploy production. citeturn0search5turn0search22

Se vuoi, ti preparo un `docker-compose.yml` e gli script già pronti con variabili (email/username/password) e un playbook per disattivare automaticamente il Local Mode dopo la creazione.