## 🧨 Istruzioni per distruggere tutto e ripartire pulito (fuori dallo script)

Da **dentro** `~/progetti/cloudetta`:

1. **Ferma e rimuovi containers + volumi del progetto**

```bash
docker compose down --volumes --remove-orphans
```

2. **Rimuovi reti del progetto** (se vuoi proprio pulizia totale)

```bash
docker network rm cloudetta_internal cloudetta_web 2>/dev/null || true
```

3. **(Opzionale) Pulisci volumi residui del progetto**
   (se qualcosa fosse rimasto per qualsiasi motivo)

```bash
docker volume ls --format '{{.Name}}' | grep '^cloudetta_' | xargs -r docker volume rm
```

4. **(Opzionale) Prune generale di Docker**
   (attenzione: elimina risorse inutilizzate anche di altri progetti)

```bash
docker system prune -a --volumes -f
```

4.1. copia i file se modificati

poi 
```bash
sed -i 's/\r$//' .env
sed -i 's/\r$//' bootstrap_cloudetta.sh
sed -i 's/\r$//' install.sh
chmod +x bootstrap_cloudetta.sh
chmod +x install.sh
```

5. **Riparti da zero**

```bash
# assicurati che .env sia corretto (LF, variabili, ecc.)
./bootstrap_cloudetta.sh
```



Se vuoi, posso anche aggiungere al bootstrap un flag tipo `CLEAN=1` per attivare una pulizia totale opzionale prima dell’up, ma ora ho fatto esattamente quanto chiesto: **ordine corretto** per Redmine nello script e **istruzioni separate** per ripartire pulito.


# Caddy in ascolto?
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep caddy

# test reverse proxy
curl -I http://django.localhost
curl -I http://odoo.localhost/web/login
curl -I http://redmine.localhost
curl -I http://nextcloud.localhost
curl -I http://n8n.localhost
curl -I http://wiki.localhost


ADMIN_USER=admin
ADMIN_PASS=ChangeMe!123
ADMIN_EMAIL=admin@example.com