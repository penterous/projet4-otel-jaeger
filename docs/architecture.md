# Architecture détaillée — Groupe 4

## 1. Périmètre

La maquette reproduit une application e-commerce minimale mais instrumentée de bout en
bout. Elle respecte le cahier des charges du Groupe 4 : au moins trois services
applicatifs (frontend, API, base de données), un collecteur OpenTelemetry officiel,
Jaeger pour la visualisation des traces, des attributs métier sur les spans et un
scénario de diagnostic reproductible.

## 2. Réseaux Docker

Deux réseaux isolent les plans :

| Réseau | Membres | Rôle |
| --- | --- | --- |
| `g4-app-net` | postgres, api, frontend, otel-collector, gateway | trafic applicatif et export OTLP |
| `g4-obs-net` | otel-collector, jaeger, prometheus, alertmanager, grafana, mailpit, cadvisor, gateway | plans d'observation |

L'API appartient aux deux réseaux : elle produit à la fois du trafic métier et des
télémétries. Le collecteur appartient également aux deux : il reçoit les traces de
l'API et du navigateur, puis les exporte vers Jaeger et Prometheus.

Aucun port n'est publié sur `0.0.0.0`. Toute exposition hôte utilise
`127.0.0.1:${PORT_*:-défaut}:port_interne`.

## 3. Chaîne de traces

### Navigateur

`frontend/www/otel-browser.js` crée un span `frontend.<action>`, injecte un en-tête
W3C `traceparent` dans chaque requête `fetch`, puis exporte le span navigateur vers
`POST /v1/traces`. Le reverse-proxy nginx du frontend relaie cette URL vers
`otel-collector:4318`, ce qui évite tout CORS et toute dépendance au port OTLP de
l'hôte. Les attributs exportés incluent `http.method`, `http.url`,
`http.response.status_code`, `http.duration.ms` et `app.trace_id`.

### API Flask

`api/telemetry.py` configure un `TracerProvider` avec :

- `Resource` : `service.name=api-backend`, `service.version=1.0.0`,
  `deployment.environment=lab`, `service.namespace=g4-observabilite` ;
- `OTLPSpanExporter` en gRPC vers `otel-collector:4317` ;
- `BatchSpanProcessor` pour limiter le nombre d'appels réseau ;
- `FlaskInstrumentor`, `Psycopg2Instrumentor`, `LoggingInstrumentor`.

`api/app.py` enrichit le span courant avec les attributs métier et crée un span
enfant `app.validate_cart`. La fonction `execute()` matérialise les attributs SQL
standard (`db.system`, `db.name`, `db.operation`, `db.statement`) et l'attribut
dédié `db.duration.ms`. En mode chaos `slow`, `SELECT pg_sleep(3)` est exécuté :
la latence est donc réelle côté PostgreSQL et visible dans le span.

Les logs Python contiennent `trace_id`, `span_id` et `resource.service.name`, ce qui
permet de passer d'un log à la trace correspondante sans outil supplémentaire.

### Collecteur

`config/otel-collector/otel-collector-config.yaml` :

- **receivers** : OTLP gRPC `4317` et OTLP HTTP `4318`, ce dernier avec CORS autorisant
  le frontend ;
- **processors** : `memory_limiter` (75 % avec marge de 20 %), `resource` (ajout de
  `deployment.environment=lab`) et `batch` (5 s / 512 spans) ;
- **connector** : `spanmetrics`, dimensions `http.route` et
  `http.response.status_code` ;
- **exporters** : `otlp/jaeger` vers `jaeger:4317`, `prometheus` sur `0.0.0.0:8889`,
  `debug` en verbosité basique ;
- **pipelines** : `traces`, `metrics/spanmetrics`, `metrics/app`.

Note de version : avec Collector Contrib `0.113.0`, la métrique dérivée s'appelle
`traces_span_metrics_calls` (pas `..._calls_total`). Les dashboards et `check.sh`
utilisent ce nom exact.

## 4. Métriques

Prometheus scrape toutes les 5 secondes :

| Job | Cible | Contenu |
| --- | --- | --- |
| `api-backend` | `api:8000/metrics` | RED, SQL, sécurité, commandes |
| `otel-collector` | `otel-collector:8889/metrics` | spanmetrics + métriques OTLP |
| `cadvisor` | `cadvisor:8080/metrics` | CPU / mémoire des conteneurs |
| `prometheus` | `localhost:9090` | santé de Prometheus |

Métriques applicatives principales :

- `http_requests_total{method,route,status}`
- `http_request_duration_seconds{method,route}`
- `app_db_query_duration_seconds{operation}`
- `app_slow_queries_total{route}`
- `app_auth_failures_total{route,reason}`
- `app_suspicious_requests_total{path}`
- `app_unhandled_errors_total{route}`
- `app_orders_total{status}`, `app_active_users`

## 5. Alertes et notification

`config/prometheus/alert_rules.yml` définit six règles réparties en deux groupes :
performance (`ApiHighErrorRate`, `ApiLatencyP95High`, `DatabaseSlowQuery`) et
sécurité/application (`AdminLoginBruteForce`, `SuspiciousPathProbing`,
`UnhandledExceptionBurst`). Chaque règle porte `severity`, `category`, `team` et des
annotations `summary`, `description`, `impact`, `runbook`.

Alertmanager regroupe par `alertname` et `category`, attend 5 s avant le premier
envoi, puis respecte un intervalle de 10 s et un `repeat_interval` de 5 min. Une
règle d'inhibition empêche qu'une alerte `warning` soit envoyée lorsqu'une alerte
`critical` de la même catégorie est déjà active. Le receiver `mail-soc` envoie à
`soc@monitoring.lab` via SMTP `mailpit:1025`, sans TLS, avec `send_resolved: true`.

Mailpit joue le rôle de serveur SMTP de laboratoire : tous les messages sont
consultables dans l'interface protégée par basic auth.

## 6. Tableaux de bord

Deux dashboards sont provisionnés automatiquement au démarrage de Grafana :

- `g4-direction` : état de santé, disponibilité, latence p95, débit, taux d'erreurs,
  ressources conteneurs et lien vers le dashboard exploitation ;
- `g4-exploitation` : spans par seconde, répartition par service, erreurs par route,
  requêtes SQL lentes, lutte contre les abus (brute-force, sondages) et lien vers
  Jaeger pour le diagnostic par Trace ID.

Les datasources Prometheus et Jaeger sont déclarées dans
`config/grafana/datasources.yml`. Grafana interdit l'accès anonyme et l'inscription
des utilisateurs ; le compte admin est renommé via `GF_SECURITY_ADMIN_USER`.

## 7. Durcissement

- secrets générés aléatoirement par `scripts/bootstrap.sh` ; `.env` ignoré par Git ;
- aucun compte par défaut dans les fichiers versionnés (`EXAMPLE_CHANGE_ME_*`) ;
- interfaces d'administration derrière un reverse-proxy nginx avec basic auth ;
- ports hôte liés à `127.0.0.1` et tous configurables ;
- `cap_drop: ALL` et `no-new-privileges:true` sur les images construites localement ;
- limites mémoire par conteneur ;
- endpoint `/internal/chaos` protégé par `X-Chaos-Token` ;
- base de données avec `scram-sha-256` et utilisateur dédié `shop_app` ;
- volumes nommés pour PostgreSQL, Prometheus, Alertmanager et Grafana.

`cadvisor` reste privilégié car la collecte des métriques système du démon Docker
le nécessite ; il n'est pas exposé directement sur l'hôte.

## 8. Chaîne de diagnostic complète

1. Le navigateur émet une commande et reçoit `X-Trace-Id`.
2. Le tableau de bord Direction montre la dégradation (latence ou erreurs).
3. Le tableau de bord Exploitation localise la route, le service ou la requête SQL.
4. Une alerte est déclenchée puis un e-mail apparaît dans Mailpit.
5. Le Trace ID est copié dans Jaeger `Search by Trace ID`.
6. Le span `db.query` porte `db.duration.ms≈3000` en mode `slow`, ou l'événement
   `exception` et `status=ERROR` en mode `error`.

Cette séquence constitue la démonstration demandée par l'épreuve du feu.
