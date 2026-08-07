# Suivi du projet

Vue d'ensemble des sprints. Contexte complet et décisions de scope dans `CLAUDE.md`.

**Entretien technique Avisto : mardi 15h.** À partir de lundi, retour sur `job-finder` — donc il ne reste concrètement que ce week-end (ven soir → dim) pour ce projet. Scope volontairement resserré à l'essentiel démontrable, voir Sprint 1.5.

## Sprint 0 — Setup & compréhension

- [x] Fork du repo `AvistoTelecom/polytech-training`
- [x] Clone en local
- [x] Exploration de l'architecture existante (`vote/`, `worker/`, `result/`, `k8s/`, `terraform/`)
- [x] Arbitrage du scope fonctionnel et technique (12 décisions, voir `CLAUDE.md`)
- [x] Mise en place `CLAUDE.md` / `SUIVI.md` / `.claude/skills`
- [ ] README + schéma d'architecture réécrits (ma compréhension du projet)

## Sprint 1 — Environnement local Docker Compose ✅

- [x] Écrire `vote/Dockerfile` (Python/Flask)
- [x] Écrire `result/Dockerfile` (Node.js/Express)
- [x] Compléter `compose.yaml` (5 services reliés : valkey, db, vote, worker, result)
- [x] Résilience au démarrage de `db` : healthcheck `pg_isready` sur `db`, `worker` et `result` en `depends_on: service_healthy`
  - Décision initiale révisée : « le retry applicatif du worker suffit » ne valait que pour le worker, qui boucle indéfiniment. `result` abandonne après 3 tentatives puis `exit(1)`, et mourait au premier démarrage à froid pendant l'`initdb` de postgres.
- [x] Multi-stage sur `worker/Dockerfile` (SDK pour compiler, `runtime:8.0` pour exécuter) — 1,29 Go → 291 Mo
- [x] `.dockerignore` sur les trois services
- [x] Vérifier le flux complet en local : vote → valkey → worker → db → result — **stack complète fonctionnelle**

## Sprint 1.5 — Objectif week-end (avant mardi)

- [ ] README + schéma d'architecture (ma compréhension du projet) — rapide, haute valeur pour l'entretien
- [ ] Nettoyage historique Git (commits conventionnels, séparation fork initial / compréhension / ajouts)
- [ ] **Un** approfondissement technique au choix (à trancher) — voir options ci-dessous
- [ ] Préparation orale : être capable d'expliquer chaque choix (Docker, connection strings, architecture) sans notes

## Sprint 2 — Worker .NET enrichi

- [ ] Remplacer le SQL brut (Npgsql) par EF Core (DbContext, migrations)
- [ ] Ajouter des retries avec Polly (au lieu des boucles `Thread.Sleep` manuelles)
- [ ] Logs structurés
- [ ] Tests unitaires de base

## Sprint 3 — CI/CD Azure DevOps

- [ ] Créer le projet Azure DevOps, connecter le repo GitHub
- [ ] Pipeline YAML : build → test → publish
- [ ] Étape deploy vers Azure App Service
- [ ] Deployment slots dev/prod (swap sans downtime)

## Sprint 4 — Infra Azure (Terraform)

- [ ] Étendre `terraform/main.tf` : App Service pour `worker` + `result`, base de données, Azure Cache for Redis
- [ ] Application Insights
- [ ] Variables/outputs propres, `.tfvars` par environnement

## Sprint 5 — Documentation & préparation entretien

- [ ] README final (schéma d'architecture, choix techniques justifiés)
- [ ] Nettoyage historique Git (branches, tags, commits conventionnels)
- [ ] Support de présentation / pitch pour l'entretien

## Backlog (stretch goals, à ne faire que si le temps le permet)

- [ ] API "Polls" ASP.NET Core (CRUD sondages, EF Core, Swagger)
- [ ] Historique des votes / authentification
- [ ] Dashboards Application Insights avancés
