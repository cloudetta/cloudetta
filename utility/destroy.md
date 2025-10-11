## 🧨 Istruzioni per distruggere tutto e ripartire pulito

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
