# Playbook des alertes — Groupe 4

Ce document est la cible des annotations `runbook` des six règles de
`config/prometheus/alert_rules.yml`. Il décrit, pour chaque alerte, le déclencheur,
la vérification immédiate, la corrélation dans Jaeger et l'action corrective.

## Rappel : accès

```bash
set -a; . ./.env; set +a
AUTH="$AUTH_USER:$AUTH_PASSWORD"
PROM="http://localhost:${PORT_PROMETHEUS:-19090}"
AM="http://localhost:${PORT_ALERTMANAGER:-19093}"
JAEGER="http://localhost:${PORT_JAEGER:-18686}"
MAIL="http://localhost:${PORT_MAILPIT_UI:-18025}"
```

Ouvrir Prometheus (`$PROM/alerts`), Alertmanager (`$AM`), Mailpit (`$MAIL`) et
Jaeger (`$JAEGER`) avec les identifiants du `.env`.

---

## ApiHighErrorRate

**Condition** : plus de 5 % de réponses 5xx sur 2 minutes, pendant 30 s.

**Comprendre** : la disponibilité de l'API est dégradée. En laboratoire, cette alerte
apparaît après l'injection `mode=error` de `scenario.sh`, qui lève une exception dans
`/api/checkout`.

**Vérifier** :

```bash
curl -fsS -u "$AUTH" "$PROM/api/v1/query?query=sum(rate(http_requests_total{status=~%225..%22}[2m]))"
curl -fsS "http://localhost:${PORT_API:-18000}/health"
```

**Corréler dans Jaeger** : rechercher les spans `POST /api/checkout` avec
`status_code=STATUS_CODE_ERROR`, puis l'événement `exception` portant
`exception.message`. L'attribut `app.chaos_mode=error` confirme l'injection.

**Action** : `./scripts/reset.sh`, puis rechargez la page de démonstration. En
production, identifier l'exception réelle dans les logs corrélés par `trace_id`
avant de rollback.

---

## ApiLatencyP95High

**Condition** : p95 de `http_request_duration_seconds` supérieur à 1 s pendant 1 min.

**Comprendre** : la latence est perceptible côté utilisateur. Le scénario `slow`
ajoute 3 s de `pg_sleep(3)` sur chaque commande, ce qui fait monter le p95 bien au-dessus
du seuil.

**Vérifier** :

```bash
curl -fsS -u "$AUTH" "$PROM/api/v1/query?query=histogram_quantile(0.95,sum%20by%20(le)(rate(http_request_duration_seconds_bucket[2m])))"
curl -fsS "http://localhost:${PORT_COLLECTOR_METRICS:-18889}/metrics" | grep traces_span_metrics_duration_count
```

**Corréler dans Jaeger** : comparer un span nominal et un span lent. Le mode `slow`
porte `app.chaos_mode=slow` et le span SQL `db.duration.ms≈3000`.

**Action** : `./scripts/reset.sh`. Si la latence persiste, vérifier le nombre de
connexions PostgreSQL et le temps d'exécution de `INSERT INTO orders`.

---

## DatabaseSlowQuery

**Condition** : `rate(app_slow_queries_total[1m]) > 0` pendant 10 s, sévérité critical.

**Comprendre** : au moins une requête SQL dépasse 1 s. C'est l'alerte la plus fiable
du scénario car elle est directement incrémentée par `execute()`.

**Vérifier** :

```bash
curl -fsS "http://localhost:${PORT_API:-18000}/metrics" | grep app_slow_queries_total
docker compose logs --tail=30 postgres
```

**Corréler dans Jaeger** : ouvrir un des Trace ID affichés par `scenario.sh`,
déplier le span `POST /api/checkout`, puis lire :
`db.statement=INSERT INTO orders (...)`, `db.duration.ms`, `app.slow_query=true`.

**Action** : mode `slow` → revenir en `nominal`. En production : examiner le plan
d'exécution, les index de `orders(user_id)` et la contention sur la base.

---

## AdminLoginBruteForce

**Condition** : plus de 5 échecs sur `/api/admin/login` en 1 minute, pendant 5 s.

**Comprendre** : tentative probable de compromission du compte administrateur.
`scenario.sh` envoie 8 échecs avec des mots de passe erronés.

**Vérifier** :

```bash
curl -fsS -u "$AUTH" "$PROM/api/v1/query?query=sum(increase(app_auth_failures_total{route=%22/api/admin/login%22}[1m]))"
```

**Corréler dans Jaeger** : chaque tentative possède un span
`POST /api/admin/login` avec `app.user.login`, `app.auth.success=false` et
l'événement `auth.failure`. Le compte attendu est `observadmin`.

**Action** : en laboratoire, aucune action : le trafic est contrôlé. En production,
bloquer l'IP source, imposer un verrouillage progressif et vérifier si un login a
finalement réussi (`app.auth.success=true`) sur la même fenêtre.

---

## SuspiciousPathProbing

**Condition** : plus de 3 requêtes vers des chemins sensibles en 1 minute.

**Chemins détectés** : `/.env`, `/wp-login.php`, `/phpmyadmin`, `/admin`, `../`.

**Comprendre** : phase de reconnaissance web, souvent précurseur d'une exploitation.
`scenario.sh` envoie quatre sondes.

**Vérifier** :

```bash
curl -fsS -u "$AUTH" "$PROM/api/v1/query?query=sum(increase(app_suspicious_requests_total[1m]))"
```

**Corréler dans Jaeger** : les spans `GET /.env`, `GET /admin`, etc. portent
`app.security.suspicious=true` et l'événement `security.suspicious_path` avec
`app.path`.

**Action** : confirmer qu'il s'agit bien du scénario de démonstration ; sinon,
contrôler les logs du reverse-proxy et appliquer une règle de blocage en amont.
Vérifier surtout qu'aucun fichier réel n'est servi par l'API (les sondes renvoient 404).

---

## UnhandledExceptionBurst

**Condition** : `rate(app_unhandled_errors_total[1m]) > 0.2`, pendant 10 s.

**Comprendre** : des exceptions Python non gérées produisent des 500. Chaque
exception est enregistrée sur le span avec sa traceback et dans les logs avec
`trace_id`.

**Vérifier** :

```bash
curl -fsS "http://localhost:${PORT_API:-18000}/metrics" | grep app_unhandled_errors_total
docker compose logs --tail=40 api
```

**Corréler dans Jaeger** : rechercher les spans au statut `ERROR` et l'événement
`exception`. Le message `Chaos injecté : exception non gérée dans checkout`
correspond au scénario.

**Action** : `./scripts/reset.sh` puis nouvelle commande. En production, corréler le
`trace_id` du log avec Jaeger, corriger la cause racine et empêcher la remontée de
détails techniques au client (le handler renvoie `str(exc)` uniquement dans la
maquette de laboratoire).

---

## Cycle de vie d'une alerte

1. Prometheus évalue les règles toutes les 5 s et passe l'alerte en `pending`.
2. Après le `for` de la règle, l'alerte passe en `firing` et est envoyée à Alertmanager.
3. Alertmanager attend `group_wait: 5s`, regroupe par `alertname`/`category`, puis
   envoie un e-mail à `soc@monitoring.lab` via Mailpit.
4. La résolution est également envoyée (`send_resolved: true`).
5. `inhibit_rules` supprime les alertes `warning` lorsqu'une `critical` de même
   catégorie est active.

`scenario.sh` attend 40 s avant d'afficher l'état des alertes et le nombre de messages
reçus, ce qui laisse le temps à ce cycle de s'écouler.
