# Guide de démonstration — Groupe 4

Durée recommandée : 8 à 10 minutes. Objectif : montrer la chaîne complète
« symptôme → métrique → alerte → trace → cause racine → correction ».

## 0. Préparer l'environnement (avant l'enseignant)

```bash
cd projet4-otel-jaeger
./scripts/start.sh
docker compose ps
```

`start.sh` enchaîne `bootstrap.sh` (si `.env` est absent), `docker compose up -d --build`
et `check.sh`. Il évite donc de démarrer la stack sans secrets générés.

`check.sh` doit afficher `[OK] Stack complete et operationnelle.`

Récupérer les identifiants sans les afficher dans le diaporama :

```bash
set -a; . ./.env; set +a
printf 'Auth: %s\n' "$AUTH_USER"
printf 'Grafana: %s\n' "$GRAFANA_USER"
```

## 1. Introduire la stack (1 min)

Montrer `docker compose ps` : 11 conteneurs, deux réseaux, ports liés à `127.0.0.1`.
Expliquer en une phrase le triptyque :

- Jaeger pour la cause racine dans la cascade de spans ;
- Prometheus pour mesurer et alerter ;
- Grafana pour lire l'état sans naviguer dans les logs.

Ouvrir <http://localhost:18080> : l'interface affiche le Trace ID courant, les
compteurs, le journal d'événements et un lien direct vers le trace dans Jaeger. La barre
supérieure donne accès à Jaeger, Grafana, Prometheus (`/alerts`) et Mailpit.

## 2. Trafic nominal (1 min)

Dans le navigateur :

1. cliquer sur `Lire les commandes` puis sur `Santé` ;
2. cliquer cinq fois sur `Passer commande` ;
3. observer les spans `frontend.list_orders`, `GET /api/orders`, `app.validate_cart`
   et le SQL dans Jaeger.

Point à faire remarquer : le navigateur et l'API partagent le même Trace ID, grâce à
l'en-tête `traceparent`. L'API renvoie aussi `X-Trace-Id` dans la réponse HTTP.

## 3. Injecter la latence SQL (2 min)

```bash
./scripts/scenario.sh
```

Le script enchaîne cinq phases. S'arrêter à la phase 2 et montrer le champ
`db.duration.ms ≈ 3000` sur un des Trace ID « commande lente ». Le span porte
`app.chaos_mode=slow` et `db.statement=INSERT INTO orders`.

Phrase clé : « Ce n'est pas une estimation : la base a réellement exécuté
`pg_sleep(3)`, et c'est le span lui-même qui mesure la durée. »

## 4. Injecter l'erreur 500 (1 min)

Toujours dans la sortie du scénario, montrer un Trace ID « commande en erreur # ».
Dans Jaeger, ouvrir `Search by Trace ID`, puis :

- span `POST /api/checkout` en erreur (`STATUS_CODE_ERROR`) ;
- événement `exception` avec le message `Chaos injecté : exception non gérée dans checkout` ;
- log API corrélé : `docker compose logs api | grep <trace_id>`.

Montrer ensuite le tableau de bord `g4-exploitation` : le panneau d'erreurs par route
et le compteur d'exceptions ont augmenté.

## 5. Sécurité et alertes (2 min)

Montrer la phase 4 : huit échecs de login puis quatre sondes de chemins sensibles.
Dans Prometheus, ouvrir `/alerts` et montrer au moins une alerte `firing`.

La phase 5 affiche le nombre d'e-mails reçus. Ouvrir Mailpit et montrer un message
d'Alertmanager avec l'objet `[G4][critical] ...`. C'est la preuve de la notification
réelle, pas d'une simulation dans le navigateur.

## 6. Direction (1 min)

Ouvrir le dashboard `g4-direction` : disponibilité, latence p95, débit, taux d'erreurs
et ressources cAdvisor. Expliquer la différence d'audience :

- Direction : « le service tient-il ses engagements ? » ;
- Exploitation : « où se situe la panne et quelle trace regarder ? ».

## 7. Corriger et conclure (1 min)

```bash
./scripts/reset.sh
curl -fsS "http://localhost:${PORT_API:-18000}/api/checkout" \
  -H 'Content-Type: application/json' \
  -d '{"user_id":1,"amount":15000}'
```

Montrer que le mode est revenu à `nominal` et qu'une nouvelle commande réussit.
Dans Alertmanager, les alertes passent en `resolved` et Mailpit reçoit la résolution
(`send_resolved: true`).

Conclusion en une phrase : « Une seule instrumentation OTel alimente trois usages :
diagnostic (Jaeger), alerte (Prometheus/Alertmanager) et pilotage (Grafana). »

## Captures à conserver pour le rapport

| Capture | Contenu attendu |
| --- | --- |
| `01-compose-ps.png` | 11 conteneurs Up, ports 127.0.0.1 |
| `02-frontend.png` | Trace ID, compteurs, journal |
| `03-jaeger-slow.png` | span SQL avec `db.duration.ms≈3000` |
| `04-jaeger-error.png` | span rouge + événement exception |
| `05-prometheus-alerts.png` | au moins une alerte firing |
| `06-mailpit.png` | un e-mail Alertmanager |
| `07-dashboard-direction.png` | vue Direction |
| `08-dashboard-exploitation.png` | vue Exploitation |

Avant de copier une capture dans le rapport, masquer les mots de passe affichés par
`scenario.sh` et ne conserver que les Trace ID et les attributs de télémétrie.

## Anti-erreurs pendant la soutenance

- Si un port est occupé : modifier la variable `PORT_*` concernée dans `.env`, puis
  `docker compose up -d`.
- Si une alerte ne déclenche pas : attendre la fenêtre `for` de la règle puis
  rafraîchir `/alerts` ; le scénario attend déjà 40 s.
- Si Jaeger est vide : vérifier que `g4-otel-collector` est `Up` et que l'API a bien
  démarré après lui (`depends_on`).
- Si Grafana affiche « No data » : vérifier que le nom de métrique est
  `traces_span_metrics_calls`, sans suffixe `_total`.
- Ne jamais régénérer `.env` pendant la démonstration : cela invaliderait les secrets
  déjà utilisés pour initialiser PostgreSQL et Grafana.
