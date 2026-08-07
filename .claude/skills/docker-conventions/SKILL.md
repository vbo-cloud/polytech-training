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

## Sécurité : ne pas tourner en `root`

Sans directive `USER`, tout process tourne en uid 0 dans le container. Une faille applicative donne alors les pleins pouvoirs *dans* le container : modifier les paquets installés, installer des outils, atteindre les autres services du réseau interne. Ce n'est pas encore root sur l'hôte — Docker retire d'office une bonne partie des capacités — mais c'est la marche d'escalier qui y mène.

Appliqué aux 3 services en Sprint 1. Ordre de préférence :

1. **Réutiliser l'utilisateur fourni par l'image de base** quand il existe — `USER node` (images `node`, uid 1000), `USER app` (images `dotnet/runtime` et `aspnet` 8.0+, uid 1654). Rien à créer.
2. Sinon le créer : `RUN useradd --create-home --uid 1000 appuser` puis `USER appuser` (cas de `python:*-slim`).

Placement : `USER` **après** les `RUN` d'installation — `pip install` / `npm ci` ont besoin de root, et les dépendances doivent rester propriété de root pour que l'app ne puisse pas les réécrire. Le `RUN useradd` en revanche reste **au-dessus** du `COPY . .` : couche stable, inutile de la rejouer à chaque modif de code.

`/app` appartenant à root, l'app non-root ne peut plus y écrire. Vérifier ce que chaque service écrit sur disque. Pour Python, ajouter `ENV PYTHONDONTWRITEBYTECODE=1` : sans ça l'échec d'écriture des `.pyc` est avalé en silence et le bytecode est recompilé à chaque import.

Vérification qui ne ment pas : `docker compose exec <service> id` doit renvoyer un uid non nul.

### Piège des ports privilégiés

Sous Linux, se lier à un port < 1024 exige root. Une app qui écoutait sur 80 ne démarre plus une fois passée en non-root. Trois issues — déplacer le port côté image, accorder `CAP_NET_BIND_SERVICE`, ou régler le sysctl `net.ipv4.ip_unprivileged_port_start`. Préférer le déplacement : les deux autres réintroduisent un privilège ou une config d'infra à répliquer partout. Vécu sur `vote/` (80 → 8000) ; `result` (4000) et `worker` (8080) n'étaient pas concernés.

⚠️ **Le mapping `ports: "8080:8000"` masque le changement en local, et seulement en local.** Avant de déplacer un port de conteneur, recenser tous ses consommateurs (voir « Analyse d'impact avant correctif » dans `CLAUDE.md`) :

| Consommateur | Ce qu'il faut changer |
|---|---|
| Dockerfile | `EXPOSE <port>` — déclare le contrat |
| Docker Compose | le mapping `ports:` |
| Azure App Service | `WEBSITES_PORT` dans les `app_settings`, sinon la plateforme sonde 80 et renvoie 502 |
| Manifests k8s | `containerPort` + le `port:` de chaque probe |

**Mais vérifier d'abord quelle image chaque consommateur déploie réellement.** Dans ce repo, `terraform/` et `k8s/` pointent tous deux `rgy.k8s.devops-svc-ag.com/polytech/vote:1.0.1` — l'image préconstruite d'Avisto, pas celle buildée ici. Les « aligner » sur le nouveau port les casserait. Le couplage n'existera que le jour où ces références pointeront une image issue de ce repo.
