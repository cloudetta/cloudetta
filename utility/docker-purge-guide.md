Ecco una **guida passo-passo** per fare il *purge* **solo** del progetto Docker nella cartella corrente, senza toccare altro.

# Obiettivo

Rimuovere in modo **chirurgico** (e verificabile) **container, immagini buildate localmente, network e volumi** che appartengono **solo** a questo progetto Compose.

---

## 1) Prerequisiti & concetti chiave

* **Project name**: Docker Compose etichetta tutto con `com.docker.compose.project=<nome>`.

  * Se hai `COMPOSE_PROJECT_NAME` nel `.env`, userà quello.
  * Altrimenti usa il **nome della cartella**.
* Lavoreremo **dentro la cartella del progetto** per evitare di toccare altro.

---

## 2) Identifica il project name e fai un “dry run”

Esegui nella **root del progetto**:

```bash
NAME=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}
echo "Project = $NAME"

docker ps -a      --filter "label=com.docker.compose.project=$NAME"
docker volume ls  --filter "label=com.docker.compose.project=$NAME"
docker network ls --filter "label=com.docker.compose.project=$NAME"
docker images     --filter "label=com.docker.compose.project=$NAME"
```

> Dovresti vedere solo risorse del tuo progetto. Se vedi *altro*, fermati: potresti essere nella cartella sbagliata o aver cambiato `COMPOSE_PROJECT_NAME` nel tempo.

---

## 3) Spegni e rimuovi risorse note a Compose

```bash
docker compose down --remove-orphans -v --rmi local
```

* `--remove-orphans`: rimuove container creati da altri file compose dello **stesso progetto**.
* `-v`: rimuove i **volumi dichiarati** nel compose (non quelli `external: true`).
* `--rmi local`: rimuove **solo le immagini buildate localmente** da questo progetto (non immagini base condivise).

---

## 4) “Colpo di scopa” per eventuali residui etichettati

> A volte rimane qualcosa etichettato (es. immagini taggate manualmente). Puliamo per **label di progetto**.

```bash
NAME=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}

# Container
IDS=$(docker ps -aq --filter "label=com.docker.compose.project=$NAME"); \
  [ -n "$IDS" ] && docker rm -fv $IDS || true

# Volumi
VOLS=$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME"); \
  [ -n "$VOLS" ] && docker volume rm $VOLS || true

# Network
NETS=$(docker network ls -q --filter "label=com.docker.compose.project=$NAME"); \
  [ -n "$NETS" ] && docker network rm $NETS || true

# Immagini buildate con label del progetto
IMGS=$(docker images -q --filter "label=com.docker.compose.project=$NAME"); \
  [ -n "$IMGS" ] && docker rmi -f $IMGS || true
```

---

## 5) Verifica che il progetto sia sparito

```bash
NAME=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}
docker ps -a      --filter "label=com.docker.compose.project=$NAME"
docker volume ls  --filter "label=com.docker.compose.project=$NAME"
docker network ls --filter "label=com.docker.compose.project=$NAME"
docker images     --filter "label=com.docker.compose.project=$NAME"
```

Se non esce niente, **perfetto**.
Controlla anche lo spazio:

```bash
docker system df
```

---

## 6) (Opzionale) Recupera altro spazio in modo prudente

Questi comandi **non** toccano ciò che è in uso **adesso** e sono in genere sicuri:

```bash
# Strati di immagini “dangling”
docker image prune -f

# Cache di build (BuildKit)
docker builder prune -f
# (facoltativo) solo cache più vecchia di 24h:
# docker builder prune --filter "until=24h" -f

# Volumi non referenziati da nessun container
docker volume ls -f dangling=true
docker volume prune -f
```

Ricontrolla poi:

```bash
docker system df
```

> **Nota**: `docker system prune -af` è più aggressivo (rimuove tutto ciò che non è in uso: immagini non usate, container stoppati, network non usate). Usa questa variante solo se sei sicuro.

---

## 7) Script pronto-uso `purge.sh` (consigliato)

Mettilo nella **root del progetto**, rendilo eseguibile (`chmod +x purge.sh`) e lancialo quando vuoi pulire **solo questo progetto**.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

NAME=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}
echo "== Purge Docker Compose project: $NAME =="

# 1) Down "ufficiale"
docker compose down --remove-orphans -v --rmi local || true

# 2) Pulizia per label
for WHAT in "containers:ps -aq" "volumes:volume ls -q" "networks:network ls -q" "images:images -q"; do
  KIND=${WHAT%%:*}
  CMD=${WHAT#*:}
  case "$KIND" in
    containers) FILTER="ps -aq --filter label=com.docker.compose.project=$NAME" && REMOVE="rm -fv" ;;
    volumes)    FILTER="volume ls -q --filter label=com.docker.compose.project=$NAME" && REMOVE="volume rm" ;;
    networks)   FILTER="network ls -q --filter label=com.docker.compose.project=$NAME" && REMOVE="network rm" ;;
    images)     FILTER="images -q --filter label=com.docker.compose.project=$NAME" && REMOVE="rmi -f" ;;
  esac
  IDS=$(eval docker $FILTER || true)
  if [ -n "${IDS:-}" ]; then
    echo "Removing $KIND: $IDS"
    docker $REMOVE $IDS || true
  else
    echo "No $KIND to remove."
  fi
done

echo "== Done. =="
```

---

## 8) Edge cases & troubleshooting

* **Project name incoerente** nel tempo
  Se in passato hai cambiato `COMPOSE_PROJECT_NAME`, alcune risorse potrebbero avere **etichette diverse**. Ripeti i comandi con il vecchio nome (es. `NAME=vecchio_nome`).
* **Volumi `external: true`**
  Non vengono toccati (by design). Se vuoi rimuoverli, fallo a mano sapendo che potrebbero essere condivisi da altri progetti.
* **Warning “`version` is obsolete”**
  In `docker-compose.yml` rimuovi la chiave `version:` (Compose v2 la ignora).
* **Immagini base condivise**
  Layer come `python:3.11-slim` restano se usati da altri progetti. È normale: evita download futuri.
* **Windows/WSL**
  Esegui tutto **dentro WSL** (Ubuntu). Se usi PowerShell, adatta le variabili (`$env:COMPOSE_PROJECT_NAME`) o lancia lo script da WSL.

---

## 9) Comandi rapidi (TL;DR)

Dentro la cartella del progetto:

```bash
docker compose down --remove-orphans -v --rmi local

NAME=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}
docker rm -fv $(docker ps -aq --filter "label=com.docker.compose.project=$NAME") 2>/dev/null || true
docker volume rm $(docker volume ls -q --filter "label=com.docker.compose.project=$NAME") 2>/dev/null || true
docker network rm $(docker network ls -q --filter "label=com.docker.compose.project=$NAME") 2>/dev/null || true
docker rmi -f $(docker images -q --filter "label=com.docker.compose.project=$NAME") 2>/dev/null || true

docker system df
```

Se vuoi, posso trasformare questa guida in un **README.md** o aggiungere un piccolo **Makefile** con il target `make purge`.
