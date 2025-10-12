Grande — Grafana è l’interfaccia dove “vedi” metriche (Prometheus) e log (Loki). Ti lascio un percorso super pratico per metterlo in uso subito.

# 1) Accedi

* Vai su **[http://grafana.localhost](http://grafana.localhost)**
* Utente/password sono quelli nel `.env`: `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD` (nel compose li hai mappati come `PROM_ADMIN_USER` / `PROM_ADMIN_PASS`).

# 2) Controlla i datasource

In Grafana: **Connections → Data sources**.
Ti servono (e di solito ci sono già, se li hai provisionati):

* **Prometheus** → URL: `http://prometheus:9090` → **Save & test** deve dire *Data source is working*.
* **Loki** (per i log) → URL: `http://loki:3100` → **Save & test** ok.

> Se uno dei due manca: **Add data source** e usa gli URL sopra (sono i nomi dei servizi docker sulla rete interna).

# 3) Importa dashboard “pronte”

Grafana → **Dashboards → New → Import** e inserisci questi ID (uno alla volta):

* **1860** – *Node Exporter Full* (CPU/RAM/Disk della macchina).
* **14282** – *cAdvisor / Container Overview* (CPU/RAM IO dei container).
* **13639** – *Loki Logs* (browser per log già impaginato).

Dopo l’ID, scegli il tuo datasource Prometheus/Loki e conferma.

# 4) Fai un panel rapido (PromQL)

Dashboards → **+ New → New dashboard → Add a new panel** → come **Query** seleziona *Prometheus* e prova:

* **Disponibilità target**
  `up`
  (linea = 1 se il target è su, 0 se giù)
* **CPU host (media 5m)**
  `100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
* **CPU container (media 5m)**
  `sum by (container_label_com_docker_compose_service)(rate(container_cpu_usage_seconds_total[5m]))`
* **RAM container**
  `sum by (container_label_com_docker_compose_service)(container_memory_usage_bytes)`

Salva il panel.

# 5) Guarda i log (Loki / LogQL)

**Explore → Loki** e prova:

* Tutti i log di un container (es. django):
  `{container="django"}`
* Solo errori:
  `{container="django"} |= "ERROR"`
* Errori per minuto:
  `sum(rate(({container="django"} |= "ERROR")[5m]))`

Puoi trasformare queste query in pannelli dashboard con **Add to dashboard**.

# 6) Allerte base (unified alerting)

* Grafana → **Alerting → Alert rules → New alert rule**
* **Query (Prometheus)**: `sum by(job)(up == 0)`
* **Condition**: > 0 per 2m → *triggera* se qualche target sparisce.
* **Contact point**: aggiungi email/webhook secondo cosa usi.

# 7) Se qualcosa non si vede

* **Prometheus targets** (vedi cosa sta scrappando): apri `http://prometheus:9090/targets` dal container o, se vuoi via browser, aggiungi una rotta in Caddy e usa `http://prometheus.localhost`.
* **cAdvisor** deve esporre le metriche a Prometheus; se il dashboard non mostra dati container, verifica in `monitoring/prometheus.yml` che ci sia un job per `cadvisor:8080` e uno per `node-exporter:9100`.
* **Loki/Promtail**: se non vedi log, controlla che `promtail` punti alla directory dei log docker (nel compose hai `${DOCKER_LOG_DIR}`) e che Loki risponda su `http://loki:3100/ready`.

Se vuoi, posso darti un `prometheus.yml` di esempio e i blocchi Caddy per esporre **prometheus.localhost** e **alertmanager.localhost**, così navighi anche quelle UI.
