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

- [x] Créer le projet Azure DevOps, connecter le repo GitHub — connexion de service `arm-poly-dev`, SP `sp-poly-pipeline-dev` scopé à `rg-poly-dev-frc`
- [x] Pipeline YAML : build → test → publish, worker uniquement (décisions #10/#11)
- [x] Étape deploy vers Azure App Service
- [x] ~~Deployment slots dev/prod~~ — abandonnés, décision #11 révisée : ils imposent un plan Standard. Un seul environnement Azure DevOps, `polytech-training-dev` ; rien ne s'appelle « prod ».
- [x] `terraform plan` sur PR vers `dev`, `terraform apply` au merge — l'infra est pilotée par le pipeline, plus à la main.
- [x] Tests : le worker n'en avait aucun. `worker.Tests/` couvre `Program.ParseVote`, seule logique isolable sans connexion réseau. Un stage `test` vide au vert vaut moins que pas de stage.
- À configurer côté Azure DevOps avant le premier run (rien de tout ça ne vit dans le YAML) :
  - groupe de variables `polytech-training-dev`, contenant **une seule entrée** : `azureServiceConnection` = `arm-poly-dev`, le nom de la connexion de service ARM.
    - N'y mettre ni `resourceGroupName`, ni `acrName`, ni `acrLoginServer`, ni `workerWebAppName` : le stage `Infra` les publie depuis `terraform output` et les stages suivants les lisent de là. Une entrée de groupe portant le même nom serait écrasée par la variable de stage, sans erreur — deux sources de vérité qui divergent en silence au premier teardown.
    - Aucun secret, et c'est le résultat visé : l'authentification passe par la connexion de service et l'identité managée de l'App Service ; l'ACR a `admin_enabled = false` et les chaînes de connexion sont écrites par Terraform dans les `app_settings`.
  - environnement `polytech-training-dev`, qui sert d'historique de déploiement. Une approbation manuelle peut y être attachée depuis l'interface, mais rien ne l'exige : le merge sur `dev` vaut décision.
    - À savoir si tu en poses une : elle ne couvrirait **que** le stage `Deploy`. Le `terraform apply` du stage `Infra` n'a pas d'`environment:`, donc aucun contrôle possible, et c'est pourtant l'étape qui peut remplacer ou détruire des ressources. L'y soumettre demanderait de convertir le job `Terraform` en `deployment` rattaché à un environnement.
- Dette et choix assumés du pipeline :
  - `az acr build` plutôt que `Docker@2` : le projet n'a qu'une connexion de service ARM, `Docker@2` en exigerait une seconde de type Docker Registry, avec ses propres identifiants. Le build tourne côté ACR, donc sans démon Docker sur l'agent.
  - L'image est reconstruite à partir de `worker/Dockerfile`, qui recompile le projet — redite du stage `build`. Le Dockerfile est celui du `docker compose` local ; en maintenir une variante CI consommant un artefact ferait diverger l'image testée en local de celle déployée. Le cache NuGet limite le coût réel.
  - `trigger.branches` inclut encore `main`, et il n'y a qu'un seul state distant. Un merge vers `main` appliquerait donc le Terraform de `main` sur le state de `dev`. Sans effet tant que `main` reste au repos (décision de branching), mais l'`apply` étant désormais automatique, il faudra une garde sur `Build.SourceBranch` — ou un second state — le jour où `main` se réveille.
  - `Npgsql` 4.1.9 est signalé vulnérable (NU1903, GHSA-x9vc-6hfv-hg8c) au restore. Non traité ici : le Sprint 2 remplace l'accès Npgsql brut par EF Core.
  - Le worker déclare sa **vivacité**, pas sa **disponibilité** : `/healthz` répond 200 dès le démarrage, avant même que Postgres et Redis ne soient joignables. C'est volontaire — un conteneur qui ne lie jamais son port est recyclé en boucle par App Service. Conséquence à connaître : une version incapable de joindre ses dépendances est déployée sans que rien ne le signale. Distinguer les deux demande un état partagé entre la boucle de traitement et le listener, prévu au Sprint 2.
  - Les stages `Publish` et `Deploy`, ainsi que le pas `terraform apply`, sont désactivés sur les validations de PR (`Build.Reason`). Une PR compile, teste et affiche le `plan` — elle montre ce qu'elle changerait sans rien changer.

## Sprint 4 — Infra Azure (Terraform)

- [ ] Étendre `terraform/main.tf` : App Service pour `result`
- [x] Registre de conteneurs : `azurerm_container_registry` SKU Basic, `admin_enabled = false`. Seule ressource publique du projet avec le front de vote — Basic ne supporte pas les private endpoints, et l'agent Microsoft-hosted du pipeline est hors du VNET.
- [x] App Service pour le `worker`, avec une identité managée titulaire du rôle `AcrPull` sur le registre.
  - **Le plan reste en B1, donc sans deployment slot.** Les tiers Free, Shared et Basic n'en supportent aucun : les slots imposaient de passer en Standard, ~5x le coût, pour une démo qui n'a pas vocation à être une prod. Décision #11 révisée en conséquence, et le stage `Promote` qui échangeait les slots a disparu. Le déploiement va directement sur l'application.
    - Contrepartie : le déploiement redémarre le conteneur, donc quelques secondes sans dépilement de la file. Les votes s'y accumulent et sont traités au redémarrage — rien n'est perdu, et le front de vote reste disponible. Remonter en Standard rétablirait le déploiement sans coupure ; c'est une ligne dans `service_plan_sku`, plus la ressource de slot et le stage de swap à réintroduire.
  - Deux registres coexistent : le worker tire de l'ACR du projet, le vote reste sur celui d'Avisto. La demande initiale était de faire pointer `registry_url` sur l'ACR ; impossible sans y pousser aussi l'image du vote, que le pipeline ne construit pas. La variable est renommée `vote_registry_url` pour que l'intention soit lisible.
  - Le tag d'image du worker appartient au pipeline : `ignore_changes` sur `docker_image_name`, sans quoi le `terraform apply` suivant annulerait le dernier déploiement. Terraform ne pose que la valeur d'amorçage, et **le worker ne démarre pas tant que le pipeline n'a pas tourné une première fois**.
  - `azurerm_app_service_virtual_network_swift_connection` remplacée par l'argument `virtual_network_subnet_id` sur chaque app : le provider interdit de mélanger les deux, et l'argument porté par la ressource évite une ressource séparée par application.
- [x] **State Terraform distant.** Imposé par le passage de l'`apply` dans le pipeline : un agent Azure DevOps est éphémère, un state local disparaît avec lui et le run suivant repartirait de zéro, donc recréerait tout.
  - Conteneur `tfstate` d'un compte `sttfstatepolydevfrc`, dans **`rg-tfstate-poly-dev-frc`** — un resource group distinct de celui que Terraform gère. Y loger le state le ferait s'effacer lui-même pendant un `terraform destroy` de teardown.
  - Amorçage fait à la main (`az group create`, `az storage account create`, `az storage container create`) : Terraform ne peut pas créer le stockage où il écrit son propre state. Versioning de blobs activé, pour pouvoir revenir sur un state écrasé.
  - Accès par Entra ID (`use_azuread_auth = true`), pas par clé de compte : rien à stocker ni à faire tourner.
  - Coût négligeable (quelques centimes par mois). Ce RG **ne doit pas** être détruit au teardown, à l'inverse de `rg-poly-dev-frc`.

- **Droits du service principal — à faire avant le premier `apply`.** `azurerm_role_assignment.worker_acr_pull` écrit une attribution de rôle, ce que `Contributor` ne permet pas. Pour que `sp-poly-pipeline-dev` puisse lancer l'`apply` lui-même, lui accorder `User Access Administrator` sur le seul resource group du projet :

  ```bash
  az role assignment create     --assignee <sp-object-id>     --role "User Access Administrator"     --scope "/subscriptions/<subscription-id>/resourceGroups/rg-poly-dev-frc"
  ```

  Portée volontairement limitée au RG, et `User Access Administrator` plutôt qu'`Owner` : le SP gagne le droit d'attribuer des rôles, pas celui de tout faire. Il ne peut pas s'accorder ce droit lui-même — c'est justement celui qui lui manque — donc l'opération se fait une fois, hors Terraform, par un compte propriétaire.

  Second rôle nécessaire, pour que le pipeline lise et écrive le state distant :

  ```bash
  az role assignment create     --assignee <sp-object-id>     --role "Storage Blob Data Contributor"     --scope "/subscriptions/<subscription-id>/resourceGroups/rg-tfstate-poly-dev-frc/providers/Microsoft.Storage/storageAccounts/sttfstatepolydevfrc"
  ```

  Rôle de plan de données, sans lequel le `terraform init` du pipeline échoue sur un 403 au conteneur — un `Contributor` sur le compte ne suffirait pas.
- [x] **Resource group importé.** `rg-poly-dev-frc` existait déjà sur Azure, vide, créé à la main pour scoper le SP : Terraform aurait voulu le créer et l'`apply` aurait échoué. Il est désormais dans le state, et le `plan` confirme qu'il correspond à la configuration — mêmes tags, même région, donc 0 modification.

  ```powershell
  terraform import azurerm_resource_group.rg "/subscriptions/<subscription-id>/resourceGroups/rg-poly-dev-frc"
  ```

  À lancer depuis PowerShell, pas Git Bash : ce dernier prend l'identifiant de ressource pour un chemin POSIX et le réécrit en `C:/Program Files/subscriptions/...`. L'erreur renvoyée parle d'un segment manquant, pas de conversion de chemin. L'import n'écrit que dans le state local et `terraform state rm` l'annule.
- [x] Base de données : `azurerm_postgresql_flexible_server` B1ms, en accès privé (sous-réseau délégué + zone DNS privée dédiée, pas de private endpoint — un serveur flexible ne fonctionne pas ainsi). Base applicative `votes`, mot de passe généré par `random_password` pour qu'aucun identifiant ne transite par `terraform.tfvars`.
  - Pas de `prevent_destroy`, à l'inverse de ce que la fiche de conventions prévoyait pour ce type : les votes sont des données de démonstration régénérables, et la protection contaminerait le resource group entier en bloquant le `terraform destroy` de teardown. La fiche est corrigée en conséquence.
  - Piège du provider : `azurerm_postgresql_flexible_server_database` porte un `prevent_destroy` **implicite**. Sans `lifecycle { prevent_destroy = false }`, le teardown échoue au plan sans dire d'où vient la protection.
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
