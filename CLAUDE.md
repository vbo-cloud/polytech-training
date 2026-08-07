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

Dossiers additionnels présents dans le repo : `k8s/`, `terraform/`. Le `terraform/main.tf` existant cible déjà **Azure App Service** (pas Kubernetes), avec un Azure Cache for Redis — c'est la piste d'hébergement retenue malgré la présence du dossier `k8s/`.

**Règles du jeu :**

- Pas de Pull Request vers Avisto : le fork reste un projet perso, la démo se fait sur mon propre repo.
- Documenter ma compréhension du code existant (README, schéma d'architecture) avant d'enrichir.
- Historique Git propre (GitFlow simplifié + Conventional Commits) pour distinguer fork initial → phase de compréhension → mes ajouts.

## Décisions de scope arbitrées

| # | Sujet | Décision |
|---|---|---|
| 1 | Fonctionnel | Vote simple (1 question, 2 options) en v1. Historique/auth en stretch goal seulement. |
| 2 | File de messages | Valkey en local, **Azure Cache for Redis** en cloud (pas Service Bus). |
| 3 | Front vote / result | Gardés tels quels (Python / Node.js) — aucune valeur DevOps à les réécrire en C#. |
| 4 | Nouvelle brique C# | Une API ASP.NET Core "Polls" (CRUD sondages, EF Core, Swagger) — priorité P2/stretch. |
| 5 | Worker .NET | Amélioré (EF Core, retries Polly, logs structurés), pas réécrit. |
| 6 | IaC | Terraform (déjà connu, déjà présent dans le repo). Pas Bicep. |
| 7 | Hébergement | Azure App Service (pas AKS) — cohérent avec le terraform existant. |
| 8 | Monitoring | Application Insights. |
| 9 | Reverse proxy | Pas de Nginx (inutile sur App Service). |
| 10 | CI/CD | Azure DevOps Pipelines (repo restant sur GitHub, pipeline piloté depuis Azure DevOps). |
| 11 | Étapes pipeline | build → test → publish → deploy, un seul environnement + deployment slots App Service pour simuler dev/prod. |
| 12 | Temps disponible | Entretien technique Avisto le mardi suivant à 15h (on est vendredi) → seulement le week-end disponible pour ce projet, puis retour sur `job-finder` dès lundi. Scope resserré à l'essentiel démontrable (voir `SUIVI.md`, Sprint 1.5). |
| 13 | Environnements Terraform | **Un seul**, `dev`. Pas de `.tfvars` par environnement : dupliquer l'infra dupliquerait le coût Azure. La séparation dev/prod se fait via les deployment slots App Service, inclus dans le plan. |
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

**Simplifié pour ce projet (week-end avant l'entretien) : pas de PR, merge direct sur `dev` en local. `main` n'est pas touchée pour l'instant** — pas de release, pas de hotfix, pas de tag tant que ce n'est pas explicitement redécidé.

- Ne jamais pousser directement sur `main` (elle reste au repos)
- `feature/*` se crée depuis `dev`, se merge directement dans `dev` en local (pas de PR GitHub)
- Historique toujours propre avant de merger (rebase interactif, commits Conventional Commits) — cette exigence ne change pas, seul le mécanisme de validation (PR) disparaît

### Workflow

- New feature : `git checkout -b feature/xxx dev`
- Merge dans dev : `git checkout dev && git merge --no-ff feature/xxx` (en local, une fois la branche prête — `--no-ff` est nécessaire pour que le hook `pre-merge-commit` se déclenche, sinon un fast-forward le contourne silencieusement)

### Hook Git

`.githooks/pre-merge-commit` bloque le merge dans `dev` si `JOURNAL.md` n'a pas été mis à jour sur la branche (vérification mécanique du passage de `docwriter`). Il ne peut pas vérifier que `reviewer` a réellement approuvé le diff — ça reste une discipline de workflow pour Claude Code, pas quelque chose qu'un script shell peut juger.

Activé via `git config core.hooksPath .githooks` (déjà fait sur ce clone — à refaire si le repo est recloné ailleurs, car cette config n'est pas versionnée automatiquement par Git).

## Git Workflow

### Before creating a new feature branch

1. `git fetch origin`
2. `git checkout dev && git merge --ff-only origin/dev`
3. `git checkout -b feature/xxx`

### Before merging into dev — mandatory sub-agent pass

Le merge est maintenant local (plus de PR GitHub), donc un vrai hook Git (`pre-merge-commit`) redevient possible techniquement si besoin plus tard — pour l'instant, ça reste une étape de workflow documentée : Claude Code doit l'exécuter systématiquement, dans cet ordre, juste avant `git checkout dev && git merge feature/xxx` :

1. **`reviewer`** (`.claude/agents/reviewer.md`) — relit le diff de la branche contre `dev`. Tout retour (bloquant ou avertissement) met le merge en pause ; Vincent lit le rapport avant de donner la consigne suivante.
2. **`docwriter`** (`.claude/agents/docwriter.md`) — seulement si `reviewer` n'a rien remonté, rédige l'entrée correspondante dans `JOURNAL.md`.

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
- Valkey (local) / Azure Cache for Redis (cloud) — file d'attente des votes

**Conteneurisation**

- Docker, Docker Compose (environnement local)

**Infra as Code**

- Terraform, provider `azurerm`

**Cloud (Azure)**

- Azure App Service (Linux, conteneurs)
- Azure Cache for Redis
- Application Insights

**CI/CD**

- Azure DevOps Pipelines (YAML), repo hébergé sur GitHub

**Autres**

- Git (branching GitFlow simplifié) + Conventional Commits
