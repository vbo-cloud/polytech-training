---
name: docker-conventions
description: Conventions expertes pour tout Dockerfile ou fichier docker-compose dans ce projet. Utilise cette skill dès qu'il s'agit d'écrire, modifier ou revoir un Dockerfile, un compose.yaml, ou de diagnostiquer un problème de build/réseau Docker. Sers-t'en aussi pour repérer les écarts entre les fichiers existants et ces conventions, et explique pourquoi la convention est préférable — plusieurs de ces règles ont été découvertes par erreur/correction pendant ce projet, donc concrètes et vérifiées.
---

# Conventions Docker — projet polytech-training

Ces règles viennent en bonne partie de vraies erreurs corrigées pendant le développement de ce projet (`vote/Dockerfile`, `result/Dockerfile`, `compose.yaml`) — pas de théorie abstraite.

## Ordre des instructions (cache de layers)

**Toujours copier le manifeste de dépendances avant le reste du code, installer, puis copier tout.** Chaque instruction Dockerfile est mise en cache par Docker ; si `COPY . .` vient avant l'installation des dépendances, le moindre changement de code invalide le cache d'installation — rebuild lent à chaque fois.

```dockerfile
# Bon ordre
COPY requirements.txt .      # ou package*.json, ou *.csproj
RUN pip install -r requirements.txt
COPY . .
```
```dockerfile
# Mauvais ordre — invalide le cache d'install à chaque modif de code
COPY . .
RUN pip install -r requirements.txt
```
`worker/Dockerfile` (fourni par Avisto) ne suivait pas cette règle — corrigé en Sprint 1.

## WORKDIR : le fixer une seule fois, tout en haut

`WORKDIR` doit venir juste après `FROM`, avant toute autre instruction. Le fixer en cours de route (après un premier `COPY`) fonctionne "par accident" grâce aux `COPY` suivants, mais laisse des fichiers orphelins ailleurs dans l'image.

```dockerfile
FROM python:3.12-slim
WORKDIR /app          # ici, pas plus bas
COPY requirements.txt .
...
```

## Versions de l'image de base

**Toujours pinner une version précise**, jamais `latest` implicite (`FROM node` = `FROM node:latest`, silencieux et non reproductible). Si le projet ne documente aucune version cible (pas de `.python-version`, pas de `engines` dans `package.json`), demander plutôt que deviner — sinon fixer une version stable récente explicitement.

Préférer les variantes `-slim` ou `-alpine` quand elles sont compatibles : image plus petite, surface d'attaque réduite.

## Réseau : `0.0.0.0`, jamais `127.0.0.1`, à l'intérieur d'un container

Le process doit écouter sur `0.0.0.0` (toutes les interfaces du container), sinon le mapping `ports:` de Docker Compose ne peut jamais l'atteindre, même correctement configuré. `127.0.0.1` à l'intérieur d'un container n'accepte que le trafic venant du container lui-même.

## Multi-stage build pour les langages compilés

Pour .NET (et tout langage avec étape de build séparée), séparer l'étape de compilation (image SDK, lourde) de l'étape d'exécution (image runtime seule, légère) :
```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /sources
COPY *.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -o /app --no-restore

FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /app .
ENTRYPOINT ["dotnet", "Worker.dll"]
```
Pourquoi : l'image finale ne contient pas le compilateur/SDK — plus petite, moins de surface d'attaque en production. Appliqué à `worker/Dockerfile` en Sprint 1 : 1,29 Go → 291 Mo. Vérifier avant de basculer sur `runtime:8.0` que le projet n'est pas un `Microsoft.NET.Sdk.Web` et ne référence aucun package ASP.NET — sinon il faut `aspnet:8.0`.

## Reproductibilité de l'installation des dépendances

- **Node.js** : `npm ci`, pas `npm i`, dans un build Docker — `ci` exige `package-lock.json`, installe exactement les versions figées, et échoue plutôt que d'improviser si le lock est désynchronisé de `package.json`. `npm i` peut modifier le lock silencieusement.
- Copier le lockfile en plus du manifeste (`COPY package*.json .` couvre les deux).

## `.dockerignore`

Un par service depuis le Sprint 1 (`vote/`, `result/`, `worker/`). Sans lui, `COPY . .` embarque `node_modules/`, `.git/`, fichiers locaux non pertinents dans le contexte de build, ce qui ralentit le build et grossit l'image inutilement.

Pire que « inutile » : un `node_modules/` construit sur l'hôte **écrase silencieusement** celui que `npm ci` vient d'installer dans l'image. Pour `result`, ça fait atterrir les bindings natifs de `pg` compilés pour Windows dans une image Linux.

## Compose : `ports:` vs réseau interne

- `ports:` sert uniquement à exposer un service vers la machine hôte (accès navigateur/Windows). Deux containers du même compose se joignent directement via le nom du service, sans jamais passer par `ports:`.
- N'ajouter `ports:` que si quelque chose *en dehors* de Docker doit atteindre ce service directement.

## Healthcheck et `depends_on` : ne pas se fier au retry applicatif

`depends_on` sans `condition` n'attend que le *démarrage* du conteneur, pas sa disponibilité. Vérifier la politique de retry de **chaque** consommateur avant de conclure qu'un healthcheck est superflu : dans ce projet, `worker` boucle indéfiniment mais `result` abandonne après 3 tentatives puis `exit(1)`. Une seule des deux apps tolérait l'attente.

```yaml
db:
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U postgres -h 127.0.0.1"]
```
Le `-h 127.0.0.1` n'est pas décoratif : l'entrypoint de l'image `postgres` démarre d'abord un serveur **temporaire socket-only** pour exécuter `initdb` et les scripts de `/docker-entrypoint-initdb.d`. Sans `-h`, `pg_isready` passe par la socket Unix et répond READY alors que le port TCP 5432 refuse encore les connexions. La fenêtre est courte sur une base vide, mais s'allonge à plusieurs secondes dès qu'un script d'init existe.

Rappel : `depends_on` ne couvre que le démarrage. Pour une app qui sort en erreur sur une coupure ultérieure, ajouter aussi `restart: unless-stopped`.

## Format des variables d'environnement en syntaxe liste YAML

```yaml
environment:
  - MA_VARIABLE=valeur      # correct
  - MA_VARIABLE="valeur"    # incorrect si mal placé : les guillemets deviennent littéraux
```
En syntaxe liste (`- CLÉ=valeur`), ne pas entourer seulement la valeur de guillemets — soit toute la ligne, soit rien si aucun caractère spécial YAML n'est présent.

## Sécurité (à considérer, pas encore appliqué dans ce projet)

Éviter de faire tourner le process en `root` à l'intérieur du container quand c'est évitable (`USER` directive). Non appliqué actuellement dans ce repo — amélioration possible à mentionner si le sujet sécurité vient en entretien.
