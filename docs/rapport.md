# Rapport projet — Observabilité applicative avec OpenTelemetry et Jaeger

Groupe 4 — L3 SI, module Monitoring

> Ce document est le support de rapport demandé : 15 à 20 pages une fois mis en forme
> (police 11 ou 12, interligne 1,5, captures en annexe). La version Markdown contient
> l'intégralité du fond ; les captures listées dans `docs/demo.md` s'insèrent aux
> sections 7, 8 et 9.

---

## Sommaire

1. Contexte et problématique
2. Cahier des charges et objectifs
3. Choix techniques et justification
4. Architecture generale
5. Instrumentation OpenTelemetry
6. Collecte, stockage et visualisation
7. Ingenierie des alertes
8. Scenario de demonstration et resultats observes
9. Securisation de la stack
10. Qualite, tests et verification
11. Limites et pistes d'amelioration
12. Conclusion
13. Annexes

---

## 1. Contexte et problématique

Une application repartie en microservices produit trois types de signaux : des traces,
des metriques et des logs. Les exploiter separement ne suffit pas : lorsqu'une requete
ralentit ou echoue, l'equipe doit pouvoir reconstituer le chemin exact de la requête,
identifier le service ou la requete SQL responsable, puis relier ce diagnostic aux
metriques et aux alertes vues par les utilisateurs.

Le sujet propose de construire une maquette d'application e-commerce et de la rendre
observable de bout en bout. La difficulte principale n'est pas d'installer Jaeger ou
Grafana, mais de produire des donnees de qualite : un contexte de trace propage du
navigateur jusqu'a PostgreSQL, des attributs metier explicites sur les spans, des
metriques qui mesurent reellement les effets d'une panne, et un routage d'alerte qui
aboutit a une notification consultable.

La problematique peut se formuler ainsi : comment concevoir une chaine d'observabilite
coherente, reproducible en une seule commande Docker Compose, qui permette a un public
non technique de voir l'etat du service et a un ingenieur de trouver la cause racine
d'une panne injectee ?

## 2. Cahier des charges et objectifs

### 2.1 Exigences du Groupe 4

- au moins trois services applicatifs : frontend, API, base de donnees ;
- instrumentation OpenTelemetry avec collecteur officiel, receveurs OTLP gRPC et HTTP,
  processeur `batch` et attributs metier ;
- export des traces vers Jaeger et visualisation par Trace ID ;
- scenario `scenario.sh` injectant une latence SQL de 3 secondes puis un code 500, avec
  diagnostic attendu via Jaeger ;
- deux tableaux de bord : Direction et Exploitation ;
- au moins quatre alertes avec notification reelle ;
- rapport ecrit et soutenance.

### 2.2 Exigences communes

- demarrage par `docker compose up -d --build` ;
- absence de credentials par defaut, fichier `.env.example` et configuration par variables
  d'environnement ;
- memes services pour tous les groupes : Flask, PostgreSQL, Jaeger, Collector, Prometheus,
  Alertmanager, Grafana, Mailpit, cAdvisor ;
- evaluation sur 20 points : fonctionnalite, qualite de l'instrumentation, pertinence des
  dashboards et alertes, securisation, clairete du rapport et de la demonstration.

### 2.3 Objectif qualite retenu

Au-dela du strict minimum, la stack vise :

1. une interface de demonstration soignee, sans emoji ni sticker, utilisant de vrais
   icones SVG ;
2. une propagation de contexte W3C complete du navigateur vers l'API ;
3. des mesures veritables : `pg_sleep(3)` cote PostgreSQL, exception reelle cote Python ;
4. des alertes documentees par un playbook exploitable ;
5. une isolation reseau et des secrets generes automatiquement.

## 3. Choix techniques et justification

### 3.1 Frontend HTML/CSS/JS

Le frontend est une page statique servie par nginx. Le JavaScript natif suffit : il n'y a
ni framework ni build a gerer, ce qui rend la demonstration lisible et le demarrage rapide.
Le style employing des variables CSS, une grille de cartes et des icones SVG inline
permet une presentation propre sans dependance externe.

Le navigateur cree ses propres spans via un petit helper `OtelBrowser`. Il n'importe pas
la bibliotheque JS officielle complete : une implementation minimale d'export OTLP/JSON
suffit pour la maquette et rend le format visible dans le code. Le contexte est propage
par l'en-tete `traceparent`, et l'export passe par le reverse-proxy nginx du frontend,
ce qui supprime les problemes de CORS.

### 3.2 API Flask

Flask est impose par le sujet et reste un excellent support pédagogique : le cycle de
requete est court, les middlewares `before_request` et `after_request` permettent
d'enrichir le span courant, et psycopg2 fournit un point d'instrumentation SQL clair.
Gunicorn avec worker `gthread` sert l'application en conteneur.

Prometheus-client fournit les compteurs et histogrammes exposes sur `/metrics`.
L'instrumentation OTel officielle (`FlaskInstrumentor`, `Psycopg2Instrumentor`,
`LoggingInstrumentor`) est preferee a une ecriture manuelle des spans HTTP et SQL :
elle garantit la conformite aux semaconventions et injecte automatiquement `trace_id`
dans les logs.

### 3.3 PostgreSQL

La base stocke deux tables, `users` et `orders`, initialisees par
`db/init/01-init.sql`. Le compte `shop_app` est dédié à l'application et l'authentification
utilise `scram-sha-256`. Le mode chaos `slow` execute `SELECT pg_sleep(3)` dans la meme
transaction que l'insertion : la latence observee est donc bien reelle et non simulee
par un simple `sleep` dans le code Python.

### 3.4 OTel Collector Contrib

L'image officielle `otel/opentelemetry-collector-contrib:0.113.0` est utilisee. Contrib
est necessaire pour le connecteur `spanmetrics`, qui derive des metriques RED directement
des traces. Le collecteur est le point de convergence : il recoit OTLP/gRPC de l'API et
OTLP/HTTP du navigateur, applique `memory_limiter`, `resource` et `batch`, puis exporte
vers Jaeger, Prometheus et un exporter `debug` utile en developpement.

Le receveur HTTP autorise explicitement les origines du frontend. Bien que le proxy
same-origin rende le CORS inutile en fonctionnement normal, cette configuration documente
l'intention et permet un test direct depuis le navigateur si necessaire.

### 3.5 Jaeger

L'image `all-in-one` est suffisante pour un laboratoire : collecteur, stockage memoire
et interface web dans un seul conteneur. Le stockage memoire est une limite assumee et
explicite ; le sujet ne demande pas de persistance des traces. L'interface est protegee
par un reverse-proxy nginx avec basic auth plutôt que d'etre exposee directement.

### 3.6 Prometheus, Alertmanager, Grafana, Mailpit, cAdvisor

- Prometheus scrape toutes les 5 secondes et conserve 7 jours de metriques ;
- Alertmanager regroupe les alertes et les route par e-mail ;
- Mailpit sert de serveur SMTP de laboratoire : aucun e-mail ne quitte la machine ;
- Grafana est provisionne : datasources et dashboards sont des fichiers versionnes ;
- cAdvisor fournit les metriques USE des conteneurs pour le dashboard Direction.

Cette combinaison couvre les trois piliers sans introduire de service superflu : chaque
conteneur a un role explicitement documente dans `docs/architecture.md`.

### 3.7 Reverse-proxy nginx

Un conteneur `gateway` termine la basic auth pour Jaeger, Mailpit, Prometheus et
Alertmanager. Le fichier `.htpasswd` est genere au demarrage depuis `.env` par
`config/nginx/entrypoint.sh`. Ainsi, aucun mot de passe n'est ecrit en clair dans
l'image ou dans les fichiers versionnes.

## 4. Architecture generale

### 4.1 Flux de donnees

```
Navigateur --traceparent--> nginx frontend --/api/*--> API Flask --SQL--> PostgreSQL
     |                                                     |
     | /v1/traces                                           | OTLP/gRPC
     v                                                      v
OTel Collector --OTLP--> Jaeger                    OTel Collector
     |-- spanmetrics --> Prometheus --> Alertmanager --> Mailpit
     `-- OTLP metrics -> Prometheus
Prometheus scrape aussi : API Flask et cAdvisor
Grafana lit Prometheus et Jaeger
```

### 4.2 Reseaux

`g4-app-net` transporte le trafic applicatif et l'export OTLP interne.
`g4-obs-net` regroupe les services d'observation. L'API et le collecteur sont les deux
services "pont" entre ces reseaux. Cette separation limite la surface d'attaque : un
conteneur de metriques ne peut pas atteindre PostgreSQL par defaut.

### 4.3 Exposition hote

Tous les ports publies sont lies a `127.0.0.1`. Les valeurs par defaut sont decalees
(`18080`, `18000`, `13000`, `18686`, `19090`, ...) pour cohabiter avec une autre stack de
TP deja demarree sur les ports standards. Chaque port est surchargeable dans `.env` via
les variables `PORT_*`.

### 4.4 Volumes

Quatre volumes nommes persistent les etats : `pgdata`, `promdata`, `amdata`,
`grafanadata`. Le stockage des traces reste memoire, conformement au choix Jaeger
all-in-one. Un `docker compose down -v` repart donc d'un etat vierge, utile apres une
regeneration des secrets.

## 5. Instrumentation OpenTelemetry

### 5.1 Resource et provider

`api/telemetry.py` cree une `Resource` avec `service.name=api-backend`,
`service.version=1.0.0`, `deployment.environment=lab` et
`service.namespace=g4-observabilite`. Le `TracerProvider` utilise un
`OTLPSpanExporter` gRPC insecure vers `otel-collector:4317` et un `BatchSpanProcessor`
(le batching cote SDK complete le batching cote collecteur).

### 5.2 Spans produits

| Operation | Origine | Attributs remarques |
| --- | --- | --- |
| `frontend.<action>` | navigateur | `http.method`, `http.url`, `http.duration.ms`, `app.trace_id` |
| `POST /api/checkout` | FlaskInstrumentor | `app.feature`, `app.user.id`, `app.order.amount_fcfa`, `app.order.id`, `app.chaos_mode` |
| `app.validate_cart` | span manuel | `app.cart.items`, `app.cart.currency` |
| spans SQL | Psycopg2Instrumentor + `execute()` | `db.system`, `db.statement`, `db.operation`, `db.duration.ms`, `app.slow_query` |
| `POST /api/admin/login` | FlaskInstrumentor | `app.user.login`, `app.auth.success`, evenement `auth.failure` |
| chemins sensibles | middleware | `app.security.suspicious`, evenement `security.suspicious_path` |

### 5.3 Logs correles

`LoggingInstrumentor.instrument(set_logging_format=True)` ajoute `trace_id` et `span_id`
a chaque ligne de log. Le handler d'exception enregistre aussi l'exception sur le span
avec `span.record_exception()` et fixe `Status(StatusCode.ERROR)`. La reponse contient
`X-Trace-Id`, `X-Span-Id` et `X-Chaos-Mode`, ce qui permet au frontend d'afficher le
Trace ID sans analyse supplementaire.

### 5.4 Attributs metier

Les attributs ne sont pas generiques : ils decrivent le domaine (commande, utilisateur,
montant FCFA) et l'etat du systeme (mode chaos, requete lente, evenement de securite).
C'est ce qui rend la trace exploitable par un developpeur qui ne connait pas l'outil :
le span lui-meme porte l'explication de la panne.

## 6. Collecte, stockage et visualisation

### 6.1 Pipelines du collecteur

Le pipeline `traces` recoit OTLP, applique `memory_limiter`, `resource` et `batch`, puis
exporte vers `otlp/jaeger`, le connecteur `spanmetrics` et `debug`. Le pipeline
`metrics/spanmetrics` convertit ces metriques en exposition Prometheus sur `8889`. Le
pipeline `metrics/app` accepte egalement des metriques OTLP.

Le connecteur `spanmetrics` declare les dimensions `http.route` et
`http.response.status_code`. La dimension `service.name` est deja fournie par le
connecteur ; l'ajouter manuellement provoquerait une erreur de validation
`duplicate dimension name service.name`. Les metriques exposees sont
`traces_span_metrics_calls` et `traces_span_metrics_duration`, sans suffixe `_total`
dans cette version du collecteur.

### 6.2 Jaeger

Jaeger recoit les traces via OTLP/gRPC et les indexe par service et par Trace ID. Trois
services apparaissent dans la demonstration : `api-backend`, `web-frontend` et
`jaeger-all-in-one` (ce dernier correspond aux auto-telemetries de l'outil). La recherche
par Trace ID affiche la cascade complete, y compris le span navigateur exporte via le
proxy du frontend.

### 6.3 Prometheus

La configuration definit quatre jobs : `prometheus`, `api-backend`, `otel-collector` et
`cadvisor`. Le fichier de regles `alert_rules.yml` est charge via `rule_files`, et
l'alertmanager est declare en `static_configs`. L'option `--web.enable-lifecycle`
permet un rechargement sans redemarrage si la configuration est modifiee.

### 6.4 Grafana

Les datasources sont provisionnees : Prometheus par defaut, Jaeger comme source de
liens de trace. Le provider charge les deux fichiers JSON du dossier `dashboards`.
L'acces anonyme et l'inscription sont desactives ; le compte admin est renomme en
`observadmin` avec un mot de passe generate.

Le dashboard `g4-direction` repond aux questions : le service est-il disponible, quelle
est la latence p95, quel est le debit, combien d'erreurs, et comment evoluent les
ressources ? Le dashboard `g4-exploitation` repond aux questions : quelle route echoue,
quel service produit des spans en erreur, quelle requete SQL est lente, et quels evenements
de securite sont detectes ?

## 7. Ingenierie des alertes

### 7.1 Catalogue

| Alerte | Condition | Severite | Equipe |
| --- | --- | --- | --- |
| ApiHighErrorRate | > 5 % de 5xx sur 2 min, `for: 30s` | critical | sre |
| ApiLatencyP95High | p95 > 1 s sur 2 min, `for: 1m` | warning | sre |
| DatabaseSlowQuery | `app_slow_queries_total` > 0 sur 1 min | critical | sre |
| AdminLoginBruteForce | > 5 echecs `/api/admin/login` sur 1 min | critical | soc |
| SuspiciousPathProbing | > 3 chemins sensibles sur 1 min | critical | soc |
| UnhandledExceptionBurst | exceptions non gerees > 0,2/s | warning | sre |

### 7.2 Annotations

Chaque regle porte un `summary`, une `description` qui indique quels attributs Jaeger
regarder, un `impact` metier et un `runbook` pointant vers `docs/playbook.md`. Cette
structure evite une alerte "oraculaire" : la personne astreinte sait immediate ment ou
aller et pourquoi l'alerte compte.

### 7.3 Routage

Alertmanager regroupe par `alertname` et `category`, avec `group_wait: 5s`,
`group_interval: 10s` et `repeat_interval: 5m`. La configuration SMTP pointe vers
`mailpit:1025` ; l'expediteur est `alertmanager@monitoring.lab` et le destinataire
`soc@monitoring.lab`. `send_resolved: true` garantit la notification de fin d'incident.
Une regle d'inhibition empeche une alerte `warning` d'etre envoyee si une `critical`
de la meme categorie est deja active.

### 7.4 Verification reelle

Lors de la validation, `scenario.sh` a genere sept messages dans Mailpit et au moins
une alerte `DatabaseSlowQuery` en etat `firing`. La notification est donc bien un
e-mail SMTP recu, et non une simulation cote navigateur.

## 8. Scenario de demonstration et resultats observes

### 8.1 Deroulement

`scripts/scenario.sh` enchaine cinq phases :

1. huit commandes nominales ;
2. trois commandes avec latence SQL de 3 secondes ;
3. cinq commandes produisant une exception non geree (HTTP 500) ;
4. huit echecs de login admin puis quatre sondes de chemins sensibles ;
5. attente de 40 s, affichage des alertes actives et du nombre d'e-mails recus.

Chaque appel renvoie un Trace ID unique, affiche en couleur dans le terminal. La fin du
script affiche les douze derniers Trace ID utiles pour la recherche dans Jaeger, ainsi
que les URL et les identifiants de toutes les interfaces.

### 8.2 Resultats observes

- 8 commandes nominales : HTTP 201, traces a deux spans
  (`POST /api/checkout` + `app.validate_cart`) ;
- 3 commandes lentes : HTTP 201, `db.duration.ms` proche de 3000 ;
- 5 commandes en erreur : HTTP 500, span en `STATUS_CODE_ERROR` et evenement `exception` ;
- 8 echecs de login : HTTP 401, evenement `auth.failure` ;
- 4 sondes : HTTP 404, attribut `app.security.suspicious=true` ;
- alertes : `DatabaseSlowQuery` en `firing` apres propagation ;
- Mailpit : 7 messages recus ;
- verification finale : 11 conteneurs Up, 10 URL HTTP 200, 2 dashboards provisionnes,
  6 regles chargees, metriques spanmetrics presentes.

### 8.3 Boucle de diagnostic

Le scenario materialise la boucle attendue par le sujet :

```
symptome (latence / 500)  ->  dashboard  ->  alerte + e-mail
        ->  Trace ID  ->  Jaeger  ->  span db.query ou exception  ->  correction
```

Le script `reset.sh` referme la boucle en remettant le mode `nominal` et en vidant
Mailpit. Les alertes passe alors en `resolved`.

## 9. Securisation de la stack

### 9.1 Secrets

`scripts/bootstrap.sh` genere avec `openssl rand -hex` les valeurs de
`POSTGRES_PASSWORD`, `ADMIN_PASSWORD`, `CHAOS_TOKEN`, `AUTH_PASSWORD` et
`GRAFANA_PASSWORD`. Le fichier `.env` resultant est en mode `600` et ignore par Git.
Le modele `.env.example` ne contient que des valeurs `EXAMPLE_CHANGE_ME_*`
intentionnellement non fonctionnelles.

### 9.2 Reseau et authentification

Tous les ports sont lies a `127.0.0.1`. Les interfaces d'administration passent par le
gateway nginx avec basic auth. Grafana desactive l'acces anonyme et l'inscription.
Le endpoint `/internal/chaos` verifie l'en-tete `X-Chaos-Token` et renvoie 403 sans
token valide.

### 9.3 Images et limites

Les images construites localement (`api`, `frontend`, `gateway`) appliquent
`no-new-privileges:true` ; l'API applique aussi `cap_drop: ALL`. Chaque service declare
une limite memoire. PostgreSQL utilise un utilisateur dedie, jamais le compte
superutilisateur par defaut.

### 9.4 Limite assumee

`cadvisor` fonctionne en mode privilégie pour lire les metriques du demon Docker. Il
n'est pas expose directement sur l'hote et il s'agit d'une contrainte technique de
cAdvisor, pas d'un oubli de durcissement.

La memoire a ete mesuree avec `docker stats --no-stream` pendant la demonstration :
les 11 conteneurs `g4-*` consomment ensemble environ **439,5 MiB (0,43 GiB)**, donc
moins que les ~800 Mo mentionnes dans le sujet. Les valeurs
`deploy.resources.limits.memory` sont des plafonds de securite et non des reservations :
leur somme (environ 3,6 GiB) ne represente pas la consommation reelle.

## 10. Qualite, tests et verification

### 10.1 Tests de configuration

Les fichiers JSON des dashboards et les fichiers YAML sont valides par analyse
programmatique. La commande `docker compose config -q` valide la syntaxe et la
resolution des variables avant tout demarrage.

### 10.2 Test de disponibilite

`scripts/check.sh` verifie :

- l'etat des 11 conteneurs ;
- 10 URL HTTP (dont 6 protegees par basic auth) ;
- la presence des deux dashboards provisionnes ;
- le chargement des six regles d'alerte ;
- la presence de la metrique `traces_span_metrics_calls`.

Il se termine par `[OK] Stack complete et operationnelle.` quand tout est vert.

### 10.3 Tests fonctionnels

Le scenario couvre les chemins nominal et dégradés, la securite et la notification.
La propagation navigateur a ete verification en envoyant un span OTLP/JSON au proxy
`/v1/traces` : le service `web-frontend` apparait dans la liste des services Jaeger et
le span `browser.action` est retrouvable par Trace ID.

### 10.4 Correction apportee pendant les tests

Trois defauts ont ete identifes et corriges :

1. `setuptools` etait absent de l'image Python : les instrumentations OTel importent
   `pkg_resources` et le worker gunicorn echouait au boot. Ajout de
   `setuptools==75.8.0` dans `api/requirements.txt` ;
2. le connecteur `spanmetrics` refusait une dimension `service.name` dupliquee :
   suppression de cette dimension, deja fournie par le connecteur ;
3. le nom de metrique `traces_span_metrics_calls_total` etait faux pour la version
   0.113.0 : remplacement par `traces_span_metrics_calls` dans les dashboards et dans
   `check.sh`.

Un conflit de port hote `3000` avec une autre stack de TP a egalement ete resolu par
la parametrisation complete des ports via `.env`.

## 11. Limites et pistes d'amelioration

### 11.1 Limites

- Jaeger all-in-one stocke les traces en memoire : elles disparaissent au redemarrage.
- Le Collector ecoute sans TLS : acceptable sur un reseau Docker local, pas en production.
- Le frontend utilise un exporteur OTLP minimal, suffisant pour la demonstration mais
  moins riche que le SDK JS officiel (`@opentelemetry/sdk-trace-web`).
- L'erreur 500 renvoie `str(exc)` au client pour rendre la demonstration lisible ; en
  production, il faudrait renvoyer un message generique.
- Les seuils d'alertes sont calibrés pour la charge du scenario, pas pour un SLO reel.
- cAdvisor est privilegie, comme explique plus haut.

### 11.2 Pistes d'amelioration

1. remplacer le stockage memoire Jaeger par Elasticsearch ou un backend persistant ;
2. ajouter des tokens d'auth sur OTLP et TLS interne via un réseau mesh ;
3. utiliser le SDK Web official pour obtenir des spans navigateur conformes aux
   semaconventions et des ressources auto-detectees ;
4. ajouter des tests unitaires sur `/api/checkout` et un test d'integration qui verifie
   la presence d'un span par appel ;
5. integreer l'export de logs dans le collecteur pour une correlation complete
   traces/logs/metriques au meme endroit ;
6. define un SLO (disponibilite, latence) et des alertes multi-fenetres basees sur les
   burn rates plutot que des seuils fixes ;
7. ajouter un pipeline CI qui execute `docker compose config -q` et `check.sh`.

## 12. Conclusion

La stack livree repond au cahier des charges du Groupe 4. Elle demarre en une commande,
produit des traces distribuees de bout en bout, expose des metriques RED et de
securite, alerte sur six situations significatives et notifie reellement par e-mail.
Les deux dashboards separent la lecture Direction de l'exploitation, et le playbook
permet de transformer chaque alerte en action concrete.

Le point central de la demonstration est la qualite du diagnostic : grace aux attributs
metier et au contexte propage, une panne injectee dans PostgreSQL ou dans le code Python
est identifiable en quelques clics dans Jaeger a partir du Trace ID affiché par
l'application. L'instrumentation n'est donc pas un simple ajout technique : elle devient
un outil de travail pour l'equipe.

Les limites identifiees (stockage memoire, absence de TLS interne, exporteur navigateur
minimal) sont assumees et documentees ; elles correspondent au cadre pédagogique d'un TP
et ne remettent pas en cause la validite de la chaine d'observabilite presentee.

## 13. Annexes

### Annexe A — Commandes essentielles

```bash
./scripts/start.sh             # bootstrap + validation + demarrage + check
./scripts/bootstrap.sh         # secrets + .env (appelé par start.sh si absent)
docker compose config -q       # validation
docker compose up -d --build   # demarrage
./scripts/check.sh             # verification complete
./scripts/scenario.sh          # demonstration complete
./scripts/reset.sh             # retour a nominal
docker compose down -v         # reset total
```

### Annexe B — Ports par defaut

| Variable | Port | Service |
| --- | --- | --- |
| `PORT_FRONTEND` | 18080 | Interface de demonstration |
| `PORT_API` | 18000 | API Flask |
| `PORT_GRAFANA` | 13000 | Grafana |
| `PORT_JAEGER` | 18686 | Jaeger (auth) |
| `PORT_MAILPIT_UI` | 18025 | Mailpit (auth) |
| `PORT_MAILPIT_SMTP` | 11025 | SMTP Mailpit |
| `PORT_PROMETHEUS` | 19090 | Prometheus (auth) |
| `PORT_ALERTMANAGER` | 19093 | Alertmanager (auth) |
| `PORT_OTLP_GRPC` | 14317 | OTLP gRPC |
| `PORT_OTLP_HTTP` | 14318 | OTLP HTTP |
| `PORT_COLLECTOR_METRICS` | 18889 | Metiques du collecteur |

### Annexe C — Fichiers de configuration importants

| Fichier | Role |
| --- | --- |
| `docker-compose.yml` | Definition des 11 services, reseaux, volumes, healthchecks |
| `.env.example` | Modele des secrets et des ports |
| `api/telemetry.py` | Provider OTel, instrumentations, exporteur OTLP |
| `api/app.py` | Routes, attributs metier, metriques, chaos |
| `frontend/www/otel-browser.js` | Traces navigateur et contexte W3C |
| `frontend/nginx.conf` | Proxies `/api/*` et `/v1/traces` |
| `config/otel-collector/otel-collector-config.yaml` | Receveurs, processeurs, pipelines |
| `config/prometheus/alert_rules.yml` | Six regles d'alerte |
| `config/alertmanager/alertmanager.yml` | Routage SMTP |
| `config/grafana/dashboards/*.json` | Dashboards Direction et Exploitation |
| `config/nginx/entrypoint.sh` | Generation de `.htpasswd` depuis `.env` |
| `scripts/*.sh` | Bootstrap, verification, scenario, reset |

### Annexe D — Captures a insérer

Se reporter a `docs/demo.md`, section « Captures a conserver pour le rapport ». Masquer
systematiquement les mots de passe avant insertion.
