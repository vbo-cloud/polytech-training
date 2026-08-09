---
name: azure-pipelines-conventions
description: Conventions expertes pour tout pipeline Azure DevOps (YAML) dans ce projet. Utilise cette skill dès qu'il s'agit d'écrire ou modifier azure-pipelines.yml, ou tout fichier de pipeline CI/CD Azure DevOps. Sers-t'en aussi pour repérer les écarts par rapport à ces conventions dans un pipeline existant et expliquer pourquoi la convention est préférable.
---

# Conventions Azure DevOps Pipelines — projet polytech-training

Référence pour la création du pipeline `worker/` (build → test → publish → deploy), décrite dans `SUIVI.md` Sprint 3, déléguée à Claude Code.

## Structure stages / jobs / steps

Organiser explicitement en stages nommés, un par grande étape du cycle de vie — pas un seul job monolithique :
```yaml
stages:
  - stage: Build
    jobs:
      - job: BuildAndTest
        steps: [...]
  - stage: Deploy
    dependsOn: Build
    condition: succeeded()
    jobs:
      - deployment: DeployToAppService
        environment: production
        strategy:
          runOnce:
            deploy:
              steps: [...]
```
Pourquoi : chaque stage apparaît séparément dans l'interface Azure DevOps (visibilité claire de ce qui a échoué), et `dependsOn`/`condition` empêchent un déploiement de partir si le build ou les tests ont échoué.

## Déclenchement (`trigger`)

Aligner le déclenchement sur le GitFlow du projet (`CLAUDE.md`) : construire sur `dev` et `main`, pas sur toutes les branches (les `feature/*` n'ont pas besoin de déclencher un pipeline complet à chaque commit, sauf validation via PR) :
```yaml
trigger:
  branches:
    include:
      - dev
      - main

pr:
  branches:
    include:
      - dev
      - main
```

## Versions de tâches (tasks) pinnées

Toujours préciser une version explicite pour chaque tâche (`UseDotNet@2`, `Docker@2`), jamais la dernière version implicite. Une tâche qui change de comportement silencieusement entre deux exécutions du pipeline est une source classique de "ça marchait hier".

## Secrets et configuration

**Jamais de secret en clair dans le YAML** (mot de passe, chaîne de connexion). Utiliser :
- les variable groups liés à Azure Key Vault, ou
- les "Library" secrets d'Azure DevOps, référencés via `$(nomDeLaVariable)`, marqués secrets (masqués dans les logs)

```yaml
variables:
  - group: polytech-training-secrets   # contient POSTGRESQL_CONNECTION_STRING etc.
```
Pourquoi : un secret commité en clair dans le repo Git reste dans l'historique pour toujours, même après suppression du fichier — cohérent avec la rigueur Git déjà établie sur ce projet (Conventional Commits, PR obligatoires).

## Artefacts entre stages

Ne pas recompiler dans chaque stage. Publier l'artefact une fois (stage Build), le télécharger dans les stages suivants :
```yaml
# Dans le stage Build
- publish: $(Build.ArtifactStagingDirectory)
  artifact: worker-build

# Dans le stage Deploy
- download: current
  artifact: worker-build
```

**Exception assumée sur ce projet : le pipeline du worker ne publie aucun artefact.** Ce qui est déployé est une image de conteneur, construite au stage `Publish` et stockée dans l'ACR — c'est elle, l'artefact transporté entre les stages. Une seconde archive `.NET` que rien ne télécharge serait de la conformité de façade.

Ce que la règle vise reste appliqué autrement : le stage `Build` restaure **tous** les `.csproj`, y compris celui du projet de test, pour que le cache NuGet qu'il enregistre couvre bien ce que sa clé annonce. Sans ça le stage `Test` obtient un *hit* sur la même clé, ne peut jamais la compléter, et retélécharge les paquets de test à chaque run — le piège est silencieux, la seule trace est la durée.

Ce qui reste vrai en toutes circonstances : ne jamais **recompiler** ce qui a déjà été compilé pour le déployer. Ici l'image est reconstruite depuis `worker/Dockerfile`, qui recompile en interne — redite tracée dans `SUIVI.md`, acceptée pour que le Dockerfile du `docker compose` local reste l'unique source de l'image.

## Cache des dépendances

Utiliser `Cache@2` pour les paquets NuGet (`~/.nuget/packages`), pour accélérer les runs répétés — équivalent du cache de layers Docker, même logique : ne pas refaire un travail identique si rien n'a changé.

## Tests avant déploiement

La stage Deploy doit dépendre explicitement du succès de la stage Test (`dependsOn: Test`, `condition: succeeded()`), pas seulement de Build. Un déploiement qui ignore l'échec des tests annule l'intérêt de les avoir.

## Environnements et approbations

Pour tout déploiement visible des utilisateurs, utiliser un `environment:` Azure DevOps avec une approbation manuelle — bonne pratique même sur un projet de démonstration.

**Les contrôles d'un environnement sont évalués au démarrage du stage**, pour tous les environnements que le stage référence, pas au démarrage du job qui les utilise. Poser une approbation sur un second job du même stage la déclenche donc *avant* le premier job. Une étape qui doit être approuvée séparément est un stage séparé.

Ce projet **n'utilise pas de deployment slots** (décision #11 : ils imposent un plan Standard, ~5x le coût de Basic). Le déploiement va directement sur l'application. Contrepartie à connaître : le conteneur redémarre, donc quelques secondes sans traitement. Acceptable ici parce que le worker consomme une file — les messages s'y accumulent — et ne le serait pas pour un service qui répond à des requêtes.
