# Groupe 4 — OpenTelemetry + Jaeger : observabilité applicative

Stack Docker Compose complète pour l'épreuve « Monitoring / APM » : traçage distribué
navigateur → API Flask → PostgreSQL, métriques RED, logs corrélés, deux tableaux de bord
Grafana, six alertes et notification e-mail réelle via Mailpit.

## Démarrage rapide

```bash
cd projet4-otel-jaeger
./scripts/start.sh          # bootstrap si besoin + compose up + check complet
./scripts/scenario.sh       # épreuve du feu : trafic, latence SQL, 500, brute-force, alertes
```

`start.sh` est le point d'entrée recommandé. Il équivaut à :

```bash
./scripts/bootstrap.sh      # génère .env avec 5 secrets aléatoires (droits 600)
docker compose up -d --build
./scripts/check.sh          # vérifie les 11 conteneurs, 10 URL, 2 dashboards, 6 alertes
```

Ouvrir l'interface de démonstration : <http://localhost:18080>.

Toutes les identifiants sont dans `.env` (jamais versionné). `scenario.sh` les affiche
en fin d'exécution pour la soutenance. Aucun compte par défaut n'est conservé dans les
fichiers versionnés.

## Arrêt et remise à zéro

```bash
docker compose down         # arrêt sans suppression des données
docker compose down -v      # arrêt + suppression des volumes (nouveau départ)
./scripts/reset.sh          # remet l'API en mode nominal et vide Mailpit
```

Si `.env` est régénéré avec `FORCE=1 ./scripts/bootstrap.sh`, les volumes PostgreSQL et
Grafana doivent être supprimés (`docker compose down -v`) : leurs données ont été
initialisées avec les anciens secrets.

## Services et accès

| Service | URL hôte | Rôle | Protection |
| --- | --- | --- | --- |
| Frontend | `http://localhost:18080` | Démonstration navigateur, trace ID visible | aucune (lecture seule) |
| API Flask | `http://localhost:18000` | Backend instrumenté, `/metrics`, `/health` | localhost only |
| Jaeger | `http://localhost:18686` | Recherche de traces par Trace ID | basic auth |
| Grafana | `http://localhost:13000` | Dashboards Direction / Exploitation | compte admin renommé |
| Prometheus | `http://localhost:19090` | Règles, cibles, état des alertes | basic auth |
| Alertmanager | `http://localhost:19093` | Routage et silence des alertes | basic auth |
| Mailpit | `http://localhost:18025` | Boîte de réception des alertes | basic auth |

Les ports sont tous liés à `127.0.0.1` et configurables dans `.env` (`PORT_*`). Cette
précaution évite les collisions avec une autre stack de TP déjà démarrée sur les ports
standards `3000`, `8080`, `9090`, `9093`, `8025`.

## Architecture

```
Navigateur (span frontend, contexte W3C traceparent)
        |
        v
nginx frontend  --/api/*-->  API Flask (spans Flask + db.query + logs corrélés)
        |                          |
        | /v1/traces                | OTLP/gRPC
        v                          v
 OTel Collector Contrib --OTLP--> Jaeger (stockage mémoire)
        |-- spanmetrics --> Prometheus --> Alertmanager --> Mailpit
        `-- OTLP metrics -> Prometheus

Prometheus scrape aussi : API Flask (/metrics) et cAdvisor (CPU/mémoire).
Grafana lit Prometheus et Jaeger via des datasources provisionnées.
```

## Ce qui est démontré

- **Traces** : cascade navigateur → API → PostgreSQL, avec attributs métier
  (`app.user.id`, `app.order.id`, `app.order.amount_fcfa`, `db.duration.ms`, `db.statement`).
- **Corrélation logs/traces** : `LoggingInstrumentor` injecte `trace_id` et `span_id`
  dans chaque log Python ; l'en-tête `X-Trace-Id` est renvoyé au navigateur.
- **Métriques** : méthode RED (`http_requests_total`, `http_request_duration_seconds`),
  métriques de sécurité et spanmetrics dérivées des traces (`traces_span_metrics_calls`,
  `traces_span_metrics_duration`).
- **Diagnostics** : `scenario.sh` injecte `pg_sleep(3)` puis une exception non gérée ;
  le Trace ID permet de retrouver le span fautif dans Jaeger.
- **Alertes** : `ApiHighErrorRate`, `ApiLatencyP95High`, `DatabaseSlowQuery`,
  `AdminLoginBruteForce`, `SuspiciousPathProbing`, `UnhandledExceptionBurst`.
- **Notification** : Alertmanager envoie de vrais e-mails SMTP à Mailpit.

## Structure du dépôt

```
api/                     API Flask, instrumentation OTel, métriques Prometheus
frontend/                Interface HTML/CSS/JS + nginx (proxy /api et /v1/traces)
config/otel-collector/   Pipelines traces, spanmetrics, exporters
config/prometheus/       Scrape + 6 règles d'alerte
config/alertmanager/     Routage SMTP vers Mailpit
config/grafana/          Datasources, provider, 2 dashboards JSON
config/nginx/            Reverse-proxy basic auth des interfaces d'admin
db/init/                 Schéma et données de démonstration
scripts/                 bootstrap, check, scenario, reset
docs/                    architecture, playbook, démo, rapport
```

## Documentation

- [Architecture détaillée](docs/architecture.md)
- [Guide de démonstration](docs/demo.md)
- [Playbook des alertes](docs/playbook.md)
- [Rapport projet](docs/rapport.md)

## Vérification attendue

`./scripts/check.sh` doit se terminer par :

```
[OK] Stack complete et operationnelle.
```

En cas d'échec : `docker compose logs --tail=50 <service>` puis
`docker compose ps` pour identifier le conteneur fautif.
