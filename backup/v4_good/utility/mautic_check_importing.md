Perfetto, ti spiego come monitorare il progresso direttamente dal **container Docker di Mautic**. 🔹

Purtroppo Mautic **non scrive log dettagliati dell’import CSV di default** e per import massivo 50k contatti il frontend può rimanere “bloccato” allo 0% anche se PHP/MySQL sta lavorando.

Ecco come vedere cosa succede:

---

### 1️⃣ Controllare i log del container Mautic in tempo reale

Dal tuo host:

```bash
docker logs -f mautic
```

* `-f` = “follow”, ti mostra i log in tempo reale.
* Puoi vedere eventuali errori PHP, limiti di memoria o timeout.

---

### 2️⃣ Controllare se ci sono processi PHP attivi

Entra nel container:

```bash
docker exec -it mautic bash
```

Poi:

```bash
ps aux | grep php
```

* Ti mostra se **il processo CLI o web PHP sta processando** i contatti.
* Se vedi CPU al 100% sul container significa che sta lavorando.

---

### 3️⃣ Verifica nel database

Se vuoi essere sicuro che i contatti siano stati importati, puoi fare un check rapido:

```bash
docker exec -it mautic-db mysql -u mautic -p
```

```sql
USE mautic;
SELECT COUNT(*) FROM leads;
```

* Ti mostra quanti contatti sono stati inseriti finora.
* Se il numero cresce lentamente, l’import sta procedendo.

---

⚡ Nota importante: per 50k+ contatti **il frontend Mautic può rimanere fermo** allo 0% anche per minuti/ore, dipende da:

* Limiti PHP (`memory_limit`, `max_execution_time`)
* Prestazioni MySQL
* Dimensione dei contatti e numero di campi custom

---

Se vuoi, posso scriverti **un comando docker + MySQL + script Python** per importare **tutti i 50k contatti in batch direttamente nel database**, così **vedi progresso reale** e non rischi timeout.

Vuoi che faccia questo?
