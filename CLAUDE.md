# CLAUDE.md

## Contexte du projet

- **Qui** : Vincent, développeur gamedev (Unity/Unreal, C#/C++) en reconversion vers Cloud/DevOps/AI Engineering.
- **Acquis** : AZ-104, Terraform et GitHub Actions (via projet perso `job-finder`).
- **Lacunes à combler** : backend web .NET, Docker en profondeur, Azure DevOps Pipelines, EF Core.
- **Objectif** : décrocher un entretien puis le poste DevOps/C# chez **Avisto** (ESN). Le projet sert de démonstration technique pour les recruteurs et de support d'apprentissage personnel.

## Le projet

Fork de [`AvistoTelecom/polytech-training`](https://github.com/AvistoTelecom/polytech-training) (licence Apache-2.0) — une application de vote distribuée qu'Avisto utilise pour former des étudiants Polytech en interne.

**Architecture originale :**

- `vote/` — front Python (Flask) : dépose un vote dans une file d'attente
- Valkey (fork de Redis) — file d'attente de messages
- `worker/` — worker .NET : lit la file, écrit en base
- Postgres — stocke les résultats
- `result/` — app Node.js : affiche les résultats en temps réel (WebSocket)

Dossiers additionnels présents dans le repo : `k8s/`, `terraform/`. Le `terraform/main.tf` existant cible déjà **Azure App Service** (pas Kubernetes), avec un Azure Managed Redis — c'est la piste d'hébergement retenue malgré la présence du dossier `k8s/`.

**Règles du jeu :**

- Pas de Pull Request vers Avisto : le fork reste un projet perso, la démo se fait sur mon propre repo.
- Documenter ma compréhension du code existant (README, schéma d'architecture) avant d'enrichir.
- Historique Git propre (GitFlow simplifié + Conventional Commits) pour distinguer fork initial → phase de compréhension → mes ajouts.

## Décisions de scope arbitrées

| # | Sujet | Décision |
|---|---|---|
| 1 | Fonctionnel | Vote simple (1 question, 2 options) en v1. Historique/auth en stretch goal seulement. |
| 2 | File de messages | Valkey en local, **Azure Managed Redis** en cloud (pas Service Bus). |
| 3 | Front vote / result | Gardés tels quels (Python / Node.js) — aucune valeur DevOps à les réécrire en C#. |
| 4 | Nouvelle brique C# | Une API ASP.NET Core "Polls" (CRUD sondages, EF Core, Swagger) — priorité P2/stretch. |
| 5 | Worker .NET | Amélioré (EF Core, retries Polly, logs structurés), pas réécrit. |
| 6 | IaC | Terraform (déjà connu, déjà présent dans le repo). Pas Bicep. |
| 7 | Hébergement | Azure App Service (pas AKS) — cohérent avec le terraform existant. |
| 8 | Monitoring | Application Insights. |
| 9 | Reverse proxy | Pas de Nginx (inutile sur App Service). |
| 10 | CI/CD | Azure DevOps Pipelines (repo restant sur GitHub, pipeline piloté depuis Azure DevOps). |
| 11 | Étapes pipeline | build → test → **infra** → publish → deploy, un seul environnement. **Pas de deployment slots** : ils exigent un plan App Service Standard, soit ~5x le coût de B1, pour une démo qui n'a pas vocation à être une prod. Le déploiement va directement sur l'application. **Aucune approbation manuelle** : une PR vers `dev` affiche le `terraform plan`, le merge applique et déploie — c'est le merge qui vaut décision. Révisé deux fois : la version initiale prévoyait des slots dev/prod, la deuxième une approbation avant déploiement. |
| 12 | Temps disponible | Entretien technique Avisto le mardi suivant à 15h (on est vendredi) → seulement le week-end disponible pour ce projet, puis retour sur `job-finder` dès lundi. Scope resserré à l'essentiel démontrable (voir `SUIVI.md`, Sprint 1.5). |
| 13 | Environnements Terraform | **Un seul**, `dev`. Pas de `.tfvars` par environnement : dupliquer l'infra dupliquerait le coût Azure. Pas non plus de séparation par slots (voir #11) — il n'y a qu'un seul emplacement de déploiement. |
| 14 | Région Azure | **France Central** (`francecentral`, jeton `frc` dans les noms). Remplace le `westeurope` hérité du repo d'origine. |

## Comment me répondre

- Je suis débutant sur beaucoup de concepts cloud/DevOps/IA : ne pars jamais du principe que je maîtrise le jargon
- Phrases courtes et concises, va à l'essentiel
- Pour chaque notion technique nouvelle ou complexe, donne une image ou une analogie simple avant (ou à la place) d'une explication technique dense
- Vulgarise d'abord ; ne détaille en profondeur que si je le demande explicitement
- Évite les pavés de texte : préfère des listes courtes à des paragraphes longs

## Collaborative workflow

This project is managed by two Claude instances with distinct roles:

**Claude Cowork** — pedagogical and design role. Answers questions, explains concepts, and produces detailed prompts broken into tasks for Claude Code. May modify documentation files (`docs/`, `memory/`, `CLAUDE.md`). Has read-only access to all other project files and never touches Terraform, Python, or PowerShell code.

**Claude Code** — execution role. Applies decisions made with Claude Cowork. Owns the full feature lifecycle: branch creation, implementation, PR opening. Has exclusive ownership of Terraform, Python, and PowerShell code.

### Conventions par stack

`.claude/skills/` contient une fiche de conventions par stack (`dotnet-conventions`, `docker-conventions`, `azure-pipelines-conventions`, `terraform-conventions` pour l'instant — voir `.claude/skills/README.md`). Claude Code doit les suivre pour tout code qu'il écrit. Claude Cowork doit s'y référer pour signaler les écarts dans le code existant ou proposé, et expliquer pourquoi la convention est préférable.

## Analyse d'impact avant correctif

**L'analyse d'impact vient avant l'action, jamais après.** Avant de proposer ou d'appliquer un correctif, recenser tout ce qui référence la valeur ou le comportement qui va changer.

Balayage minimum, à faire sur l'ensemble du repo :

- toute autre occurrence de la valeur (port, nom de variable, chemin, version, nom de service)
- les fichiers de configuration et d'infra : `compose.yaml`, `terraform/`, `k8s/`, pipelines CI
- la documentation qui l'énonce : `README.md`, `SUIVI.md`, `.claude/skills/`
- ce que le changement rend faux ailleurs, même sans erreur visible

Vérifier aussi **qui consomme réellement** l'objet modifié avant d'en conclure quoi que ce soit. Exemple vécu : `terraform/` et `k8s/` référencent une image externe figée du registre d'Avisto, pas celle construite ici — les « aligner » sur un changement local les aurait cassés au lieu de les corriger.

Ensuite seulement, agir : **tous les correctifs nécessaires dans un seul commit**. Un correctif qui fait apparaître un nouveau problème à la passe de revue suivante signale que l'analyse n'a pas été faite.

Ce que l'analyse ne couvre pas doit être écrit — dans `SUIVI.md` en dette, ou dans la fiche de conventions concernée. Pas seulement dit en conversation.

## Git branching strategy

- `main` → stable, production-ready, always tagged with `vMAJOR.MINOR.PATCH`
- `dev` → integration branch, base for all feature branches
- `feature/*` → one feature per branch, always from `dev`
- `hotfix/*` → urgent fix from `main`, merged back to both `main` and `dev`

### Branch rules

**Révisé le 2026-08-09 : PR GitHub entre `feature/*` et `dev`, mergée via le bouton GitHub.** Nécessaire pour que le pipeline Azure DevOps fonctionne comme conçu (`azure-pipelines.yml`, décision #11) : une PR affiche le `terraform plan` en preview, rejoué à chaque push tant qu'elle reste ouverte ; le merge déclenche l'`apply`. Un merge local (`git merge`) ne passe jamais par GitHub, donc ne déclenche jamais le pipeline — la version précédente de cette règle («pas de PR, merge direct en local») avait été simplifiée pour la vitesse du week-end, sans tenir compte du fait que le pipeline, lui, avait été conçu autour d'une PR dès son premier commit. `main` n'est pas touchée pour l'instant — pas de release, pas de hotfix, pas de tag tant que ce n'est pas explicitement redécidé.

- **Aucun commit direct sur `dev` ou `main`, sans exception — y compris pour un correctif d'une ligne ou un changement de doc.** Toute modification, quelle que soit sa taille, passe par `feature/*` → push → PR → merge GitHub. Une branche à un seul commit reste une branche.
- Ne jamais pousser directement sur `main` (elle reste au repos)
- `feature/*` se crée depuis `dev`, se pousse sur GitHub, se merge dans `dev` via une Pull Request
- Merge strategy : **"Create a merge commit"** — seule option activée côté GitHub (`allow_squash_merge`/`allow_rebase_merge` désactivés au niveau du repo), pas seulement une consigne. L'historique doit déjà être propre avant la PR (rebase interactif, Conventional Commits) : la PR expose ce qui est prêt, elle ne le nettoie pas à la place de Claude Code
- Historique toujours propre **avant de pousser la branche** : cette exigence ne change pas, seul le moment où l'historique devient visible/mergeable change
- `dev` et `main` sont protégées côté GitHub (branch protection rules) : push direct refusé par GitHub lui-même, pas seulement par discipline — voir section Hook Git

### Workflow

- New feature : `git checkout -b feature/xxx dev`
- `reviewer` puis `docwriter` tournent en local sur la branche, comme avant — `JOURNAL.md` est commité sur `feature/xxx` avant tout push
- Ouvrir la PR : `git push -u origin feature/xxx`, puis `gh pr create --base dev` (ou l'interface GitHub) — déclenche le `plan` Terraform en preview sur la PR
- Merge : bouton GitHub ("Create a merge commit"), jamais `git merge` en local pour cette étape — c'est ce merge, poussé par GitHub sur `dev`, qui déclenche l'`apply`
- Après merge : `git fetch origin && git checkout dev && git merge --ff-only origin/dev` en local, pour resynchroniser avant la branche suivante

### Hook Git

`.githooks/pre-merge-commit` bloque un `git merge --no-ff` **local** dans `dev` si `JOURNAL.md` n'a pas été mis à jour sur la branche entrante (vérification mécanique du passage de `docwriter`). **Il ne peut plus se déclencher dans ce projet** : `dev` et `main` sont protégées côté GitHub avec `enforce_admins` actif (section suivante), donc même un `git merge` local suivi d'un `git push` serait rejeté par GitHub avant que quiconque n'atteigne la branche — il n'existe plus de chemin, y compris pour un hotfix pressé, qui contourne la PR. Le hook devient un vestige, laissé en place sans scénario d'usage réel plutôt que supprimé. Pour le flux PR, la vérification que `docwriter` est passé avant l'ouverture de la PR redevient — comme celle de `reviewer` l'a toujours été — une discipline de workflow pour Claude Code, pas quelque chose qu'un script shell peut juger.

Activé via `git config core.hooksPath .githooks` (déjà fait sur ce clone — à refaire si le repo est recloné ailleurs, car cette config n'est pas versionnée automatiquement par Git).

### Protection des branches (GitHub)

`dev` et `main` portent une règle de protection GitHub (*Settings → Branches → Branch protection rules*) : PR obligatoire pour atteindre la branche, push direct refusé par GitHub lui-même — un filet mécanique, pas seulement une discipline documentée ici. Contrairement au hook `pre-merge-commit`, ça s'applique même à un `git push` direct qui ne passerait par aucun outil Claude Code.

## Git Workflow

### Before creating a new feature branch

1. `git fetch origin`
2. `git checkout dev && git merge --ff-only origin/dev`
3. `git checkout -b feature/xxx`

### Before opening the PR — mandatory sub-agent pass

Le merge passe maintenant par une PR GitHub, donc aucun hook Git local ne peut plus l'intercepter (voir section Hook Git) — c'est une étape de workflow documentée, pas mécaniquement vérifiée : Claude Code doit l'exécuter systématiquement, dans cet ordre, juste avant `git push -u origin feature/xxx` :

1. **`reviewer`** (`.claude/agents/reviewer.md`) — relit le diff de la branche contre `dev`. Tout retour (bloquant ou avertissement) met le push en pause ; Vincent lit le rapport avant de donner la consigne suivante.
2. **`docwriter`** (`.claude/agents/docwriter.md`) — seulement si `reviewer` n'a rien remonté, rédige l'entrée correspondante dans `JOURNAL.md`.

Une fois la PR ouverte, la vérifier régulièrement (`gh pr checks` ou l'interface GitHub) : si la PR touche `worker/*`, `worker.Tests/*`, `terraform/*` ou `azure-pipelines.yml` (filtre `pr:` du pipeline), le `terraform plan` du stage `Infra` s'y affiche, à relire avant de merger — c'est lui qui remplace la relecture humaine du hook `pre-merge-commit` pour la partie infra. Une PR qui ne touche aucun de ces chemins (doc, `.claude/`, etc.) ne déclenche aucun run : c'est attendu, pas une panne à investiguer.

### Avant de merger, ou si la branche a du retard sur `dev`

1. `git stash` les modifications locales en cours
2. `git rebase -i origin/dev` — commits atomiques, Conventional Commits
3. `git rebase origin/dev` (jamais de merge pour rattraper le retard)
4. `git stash pop`

### Commit conventions (Conventional Commits)

- `feat:` new feature
- `fix:` bug fix
- `chore:` maintenance task
- `docs:` documentation
- `refactor:` code restructuring

### Rules

- Jamais de merge dans `dev` avec des commits WIP ou non atomiques
- Toujours rebase pour rattraper `dev`, jamais de merge pour ça
- `main` reste intouchée jusqu'à nouvel ordre

## Stack technique

**Langages / runtimes**

- C# / .NET 8 — worker, future API "Polls"
- Python (Flask) — `vote/`, inchangé
- Node.js (Express, Socket.IO) — `result/`, inchangé

**Backend .NET**

- ASP.NET Core Web API
- EF Core (accès base de données, migrations)
- Polly (retries / résilience)

**Data & messaging**

- PostgreSQL — stockage des résultats
- Valkey (local) / Azure Managed Redis (cloud) — file d'attente des votes

**Conteneurisation**

- Docker, Docker Compose (environnement local)

**Infra as Code**

- Terraform, provider `azurerm`

**Cloud (Azure)**

- Azure App Service (Linux, conteneurs)
- Azure Managed Redis
- Application Insights

**CI/CD**

- Azure DevOps Pipelines (YAML), repo hébergé sur GitHub

**Autres**

- Git (branching GitFlow simplifié) + Conventional Commits
