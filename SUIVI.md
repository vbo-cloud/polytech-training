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
- [x] Les 3 services tournent en non-root (`USER`) — `vote` a dû quitter le port 80, réservé à root sous Linux, pour 8000
  - `terraform/` et `k8s/` ne sont **pas** à réaligner : ils déploient l'image préconstruite d'Avisto (`rgy.k8s.devops-svc-ag.com/polytech/vote:1.0.1`), pas celle buildée ici. Les toucher casserait le déploiement.
  - Dette conditionnelle : le jour où `web_app_vote_docker_image_name` pointera une image issue de ce repo, il faudra ajouter `WEBSITES_PORT = "8000"` aux `app_settings` du web app, sinon App Service sonde 80 et renvoie 502.
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
- [x] Tests unitaires de base — xUnit sur `Program.ParseVote` (`worker.Tests/`)
  - Dette identifiée par ces tests, volontairement hors scope : un `voter_id` manquant dans la charge utile n'est pas rejeté, il passe en base tel quel (`ParseVote_WithMissingVoterId_LeavesItNull`). Validation à ajouter avec le passage à EF Core.
- [ ] Distinguer liveness et readiness sur `/healthz` (`worker/Program.cs`) : le worker se déclare vivant dès le démarrage, pas prêt — il répond 200 alors qu'il attend peut-être encore sa base. Demande un état partagé entre la boucle de traitement et le listener.

## Sprint 3 — CI/CD Azure DevOps

- [ ] Créer le projet Azure DevOps, connecter le repo GitHub
- [ ] Pipeline YAML : build → test → publish
- [ ] Étape deploy vers Azure App Service
- [ ] Deployment slots dev/prod (swap sans downtime)

## Sprint 4 — Infra Azure (Terraform)

- [ ] Étendre `terraform/main.tf` : App Service pour `worker` + `result`, base de données, Azure Cache for Redis
- [ ] Application Insights
- [ ] Variables/outputs propres — un seul environnement, un seul `terraform.tfvars` (décision #13)
- [x] `terraform/` aligné sur les conventions de nommage du projet : `{type}-[role-]poly-dev-frc` construit via `local.base_name`, tags `environment`/`project`/`owner` sur toutes les ressources Azure dont le type expose l'argument — les 2 subnets et la swift connection ne l'exposent pas côté provider —, région France Central. Rien n'était déployé, donc renommage sans recréation.
- [x] Versions figées : provider `random` déclaré dans `required_providers` — il était résolu implicitement, donc non pinné —, cœur Terraform pinné via `required_version`, `.terraform.lock.hcl` versionné et régénéré pour `windows_amd64` et `linux_amd64`.
- [x] `registry_url` et `web_app_vote_docker_image_name` rendues obligatoires : leur `default = ""` faisait retomber App Service sur Docker Hub sans que le `plan` bronche. Validations ajoutées sur le schéma https et sur la présence d'un tag explicite autre que `latest`.
- [x] Redis fermé sur Internet : `public_network_access_enabled = false`. Il était laissé à `true` par défaut, donc joignable depuis n'importe où sur 6380 avec la seule clé — le private endpoint, la zone DNS privée et l'enregistrement A étaient payés pour rien.
  - Deux corrections couplées, sans lesquelles fermer l'accès public cassait le vote au runtime avec un `plan` propre :
    - l'enregistrement A privé était maintenu à la main et recevait le FQDN du Redis au lieu du seul label d'hôte, ce qui produisait `xxx.redis.cache.windows.net.privatelink.redis.cache.windows.net`. Il est désormais délégué à Azure via `private_dns_zone_group` sur le private endpoint — la classe d'erreur disparaît avec la ressource.
    - `vnet_route_all_enabled = true` sur la Web App. L'intégration VNET seule ne route pas le DNS de l'app à travers le VNET (défaut du provider : `false`) : elle aurait résolu le nom public du cache vers son IP publique, qu'on venait de fermer.
  - `terraform fmt -check`, `validate` et `plan` vérifiés sur l'état final : 12 objets à créer, 0 à détruire, noms conformes au pattern dans la sortie du plan. Rien n'est déployé sur Azure.
- Dette identifiée pendant cet alignement, volontairement hors scope :
  - `main.tf` — la clé Redis est injectée en clair dans les `app_settings` de la Web App, donc écrite en clair dans le state. Cible propre : Key Vault + identité managée. Le state est gitignoré et le cache n'est plus exposé publiquement : la clé seule ne suffit plus à l'atteindre, il faut être dans le VNET. Le risque est réduit, pas supprimé.

## Sprint 5 — Documentation & préparation entretien

- [ ] README final (schéma d'architecture, choix techniques justifiés)
- [ ] Nettoyage historique Git (branches, tags, commits conventionnels)
- [ ] Support de présentation / pitch pour l'entretien

## Backlog (stretch goals, à ne faire que si le temps le permet)

- [ ] API "Polls" ASP.NET Core (CRUD sondages, EF Core, Swagger)
- [ ] Historique des votes / authentification
- [ ] Dashboards Application Insights avancés
