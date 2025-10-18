yay — ottimo! adesso che i log fluiscono, ecco un mini-tour pratico per usare Grafana+Loki senza perdersi.

# Come leggere i log (Explore)

1. vai su **Explore** (bussola a sinistra), seleziona **Loki**.
2. in alto scegli **Time range** (es. Last 15m).
3. nella casella di query scrivi **LogQL** (il linguaggio dei log).

## LogQL in 60 secondi

* I log sono **serie etichettate**. Esempi di etichette tipiche: `{container="mautic", compose_service="redmine", filename="/var/log/…", host="…"}`
* Parti sempre con un **selettore di etichette** e poi **filtri** con pipe.

### Selettori base

```logql
{}                                # tutto (non farlo su range lunghi 😅)
{compose_service="redmine"}       # solo i log del servizio redmine
{container="nextcloud"}           # solo container Nextcloud
{job="varlogs"}                   # in base alla job di promtail (se definita)
```

### Filtri di testo

```logql
{compose_service="redmine"} |= "ERROR"        # contiene "ERROR"
{container="mautic"} |~ "(?i)exception"       # regex case-insensitive
{container="django"} != "DEBUG"               # esclude "DEBUG"
```

### Pipeline (parsing e formattazione)

```logql
{container="django"} | json                                   # prova a fare parse JSON
{container="django"} | json | line_format "{{.message}}"      # mostra solo il campo message
{container="n8n"} | label_format(svc="{{compose_service}}")   # rinomina una label
```

### Metriche dai log (conteggi, top, error-rate)

```logql
# numero di linee al secondo (totale)
sum(rate({}[$__interval]))

# errori al secondo per servizio (stacked area perfetto)
sum by (compose_service) (rate({} |= "error" [$__interval]))

# top 5 container più “chiassosi” (ultimi 15m)
topk(5, sum by (container) (rate({}[$__interval])))

# “5xx” vistosissimi su reverse proxy (se li hai nei log)
sum by (compose_service) (rate({} |~ " (5\\d\\d) " [$__interval]))
```

> Tip: `$__interval` lo imposta Grafana in base allo zoom. In Explore puoi cambiare “Format” su **Logs** (per testo) o **Table**/**Time series** (per metriche).

---

# Cose utili da cliccare

* **Live tail** (tasto ▶ Live): tail -f nel browser.
* **Dedup**: elimina ripetizioni visive (icona “Dedup” sopra la lista log).
* **Labels**: espandi una riga -> vedi tutte le etichette presenti. Usa quelle per la tua query.
* **Flame graph / Distribution**: viste alternative per capire picchi e ripetizioni.

---

# Una dashboard “starter” in 3 pannelli

1. **Error rate per servizio** (Time series)

   ```logql
   sum by (compose_service) (rate({} |= "error" [$__interval]))
   ```

   Unità: “ops” (operations per second). Stacked = On.

2. **Top container per volume di log** (Bar chart)

   ```logql
   topk(10, sum by (container) (rate({}[$__interval])))
   ```

3. **Ultime eccezioni** (Logs panel)

   ```logql
   {container=~"django|odoo|nextcloud"} |~ "(?i)(error|exception|traceback)"
   ```

   Dedup = Outgoing, Show labels = container,compose_service.

Salva la dashboard in una cartella “Observability”.

---

# Quando qualcosa non si vede

* **Data source**: Grafana → ⚙️ **Data sources** → **Loki** → **Save & test** deve dire “Data source is working”.
* **Permesso**: se query restituisce 0, prova un range più ampio (Last 1h) e togli filtri troppo stretti.
* **Promtail**: `docker compose logs -n 100 promtail` per verificare che stia pushando verso `http://loki:3100`.

---

# Piccoli trucchi

* Se i log sono JSON, usa `| json` e poi `| line_format "{{.field}}"` per renderli leggibili.
* Se vuoi cercare una richiesta HTTP specifica:
  `{container="caddy"} |~ "GET /api/v1/items" |= "200"`
* Per investigare un singolo container: filtra `{container="nome"}` e attiva **Live** durante la riproduzione del bug.

Se vuoi, ti preparo una **dashboard pronta** con quei pannelli e qualche query “best practice” per i tuoi servizi (django, odoo, nextcloud, caddy, redmine, mautic). Dimmi solo i nomi esatti delle label più comode (es. `compose_service`, `container`) che vedo nei tuoi log e te la scrivo su misura.
