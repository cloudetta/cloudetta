## 🧨 Istruzioni per distruggere tutto e ripartire pulito

```bash
docker compose down --volumes --remove-orphans
docker network rm cloudetta_internal cloudetta_web 2>/dev/null || true
docker system prune -a --volumes -f
docker ps -aq --filter "label=com.docker.compose.project=cloudetta" | xargs -r docker rm -f
docker rm -f caddy 2>/dev/null || true
docker network ls -q --filter "label=com.docker.compose.project=cloudetta" | xargs -r docker network rm
docker volume ls -q --filter "label=com.docker.compose.project=cloudetta" | xargs -r docker volume rm
docker rm -f $(docker ps -aq --filter "name=^cloudetta-") 2>/dev/null || true
docker compose down --volumes --remove-orphans
docker compose --profile monitoring --profile logging --profile backup --profile office --profile sso --profile errors --profile uptime down --volumes --remove-orphans
docker system prune -a --volumes -f
```

```bash
cd ..
rm -rf cloudetta
```
```bash
sed -i 's/\r$//' .env
sed -i 's/\r$//' bootstrap_cloudetta.sh
sed -i 's/\r$//' install.sh
sed -i 's/\r$//' caddy/entrypoint.sh
sed -i 's/\r$//' mautic/cron-runner.sh
sed -i 's/\r$//' .env
# (facoltativo) rimuovi un eventuale BOM in testa
sed -i '1s/^\xEF\xBB\xBF//' .env
chmod +x bootstrap_cloudetta.sh
chmod +x install.sh
chmod +x mautic/cron-runner.sh
chmod +x caddy/entrypoint.sh
```

```bash
# assicurati che .env sia corretto (LF, variabili, ecc.)
./bootstrap_cloudetta.sh
```

Da **dentro** `~/progetti/cloudetta`:

1. **Ferma e rimuovi containers + volumi del progetto**

```bash
docker compose down --volumes --remove-orphans
```

2. **Rimuovi reti del progetto** (se vuoi proprio pulizia totale)

```bash
docker network rm cloudetta_internal cloudetta_web 2>/dev/null || true
```


4. **(Opzionale) Prune generale di Docker**
   (attenzione: elimina risorse inutilizzate anche di altri progetti)

```bash
docker system prune -a --volumes -f
cd ..
rm -rf cloudetta
```



Capito: alcuni container dei **profili extra** (monitoring/logging/backup/office…) sono rimasti su, quindi la network `cloudetta_internal` risulta “in uso”. Succede spesso se:

* hai avviato i profili extra con il bootstrap (compose up separati),
* poi hai cancellato la cartella del progetto (Compose non ha più il file per “governarli”),
* o hai cambiato il compose e `down` non li ha presi tutti.

Vai di “pulizia chirurgica” per **tutto il progetto `cloudetta`** usando le **label** di Compose (non serve il file YAML).

### 1) Spegni e rimuovi TUTTI i container del progetto `cloudetta`

```bash
# stop + rm forzato di ogni container con label del progetto
docker ps -aq --filter "label=com.docker.compose.project=cloudetta" \
  | xargs -r docker rm -f
```

> Se per caso resta il `caddy` nominale:

```bash
docker rm -f caddy 2>/dev/null || true
```

### 2) Rimuovi le network del progetto

```bash
docker network ls -q --filter "label=com.docker.compose.project=cloudetta" \
  | xargs -r docker network rm
```

### 3) Rimuovi i volumi del progetto

```bash
docker volume ls -q --filter "label=com.docker.compose.project=cloudetta" \
  | xargs -r docker volume rm
```

### 4) (Facoltativo) Rimuovi **solo** ciò che vedi ancora con prefisso

Se qualcosa fosse rimasto con il naming v2 (es. `cloudetta-*-1`):

```bash
docker rm -f $(docker ps -aq --filter "name=^cloudetta-") 2>/dev/null || true
```

### 5) Verifica

```bash
docker ps
docker network ls | grep cloudetta || true
docker volume ls | grep cloudetta || true
```

Se l’obiettivo è **ricominciare da zero** in modo “gentile” la prossima volta, invece di cancellare la cartella prima del `down`, fai così nell’ordine:

```bash
# dentro la cartella del progetto (finché esiste)
docker compose down --volumes --remove-orphans

# in più: profili extra che il bootstrap ha acceso
docker compose --profile monitoring --profile logging --profile backup --profile office --profile sso --profile errors --profile uptime down --volumes --remove-orphans
```

> Poi, **se serve davvero** lo “sgombero” totale:

```bash
docker system prune -a --volumes -f
```

Con i comandi sopra dovresti eliminare i residui che vedi ora (`loki`, `grafana`, `prometheus`, `alertmanager`, `promtail`, `node-exporter`, `uptime-kuma`, `minio`, `collabora`, `keycloak-db`, e il `caddy` nominato). Dopo il punto 1–3, la `cloudetta_internal` non risulterà più “in use”.





4.1. copia i file se modificati
4.2. assicurati che i file abbiano LF come terminatore di linea (non CRLF) e siano eseguibili
poi 
```bash
sed -i 's/\r$//' .env
sed -i 's/\r$//' bootstrap_cloudetta.sh
sed -i 's/\r$//' install.sh
sed -i 's/\r$//' caddy/entrypoint.sh
sed -i 's/\r$//' .env
# (facoltativo) rimuovi un eventuale BOM in testa
sed -i '1s/^\xEF\xBB\xBF//' .env
chmod +x bootstrap_cloudetta.sh
chmod +x install.sh
chmod +x caddy/entrypoint.sh
```

5. **Riparti da zero**

```bash
# assicurati che .env sia corretto (LF, variabili, ecc.)
./bootstrap_cloudetta.sh
```



Se vuoi, posso anche aggiungere al bootstrap un flag tipo `CLEAN=1` per attivare una pulizia totale opzionale prima dell’up, ma ora ho fatto esattamente quanto chiesto: **ordine corretto** per Redmine nello script e **istruzioni separate** per ripartire pulito.

Sì, quel Caddyfile va benissimo per l’uso **solo locale**. È sintatticamente corretto (blocchi multi-linea) e mappa ogni `*.localhost` al rispettivo servizio nella rete docker.

Mini check-list per applicarlo al volo:

1. **Validalo** fuori container (giusto scrupolo):

```bash
docker run --rm -v "$PWD/caddy:/caddy:ro" caddy:2 \
  caddy validate --config /caddy/Caddyfile
```

2. **Ricarica Caddy** (senza restart dello stack):

```bash
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
# se fallisse:
docker compose restart caddy
```

3. **Smoke test**:

```bash
curl -I http://django.localhost
curl -I http://odoo.localhost
curl -I http://redmine.localhost
curl -I http://wiki.localhost
curl -I http://nextcloud.localhost
curl -I http://mautic.localhost
curl -I http://n8n.localhost
```

Note rapide:

* I nomi `django`, `odoo`, `redmine`, `dokuwiki`, `nextcloud`, `mautic`, `n8n` devono corrispondere esattamente ai **service name** del `docker-compose.yml` (così Caddy li risolve sulla network compose).
* In locale è ok **senza TLS** (`auto_https off`).
* Se in futuro abiliti domini pubblici/https, aggiungeremo blocchi separati con i FQDN.
