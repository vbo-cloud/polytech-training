# Journal du projet

Un log par branche, écrit avant chaque PR. Sert à retracer *pourquoi* chaque changement a été fait, pas juste *quoi* — utile pour l'entretien, et pour reprendre le fil après une pause.

## Format

```
## #<numéro> — <nom-de-branche>

**Contexte avant** : état du projet juste avant cette branche, en 1-2 phrases.

**Objectif** : ce que cette branche doit produire, résultat attendu.

**Ce qui a été fait** : liste concise des changements réels.

**Décisions techniques** *(uniquement si un choix peut sembler surprenant sans explication)* : quoi, pourquoi ce choix plutôt qu'un autre évident.
```

---

## #1 — feature/dockerfiles

**Contexte avant** : le fork amont d'Avisto ignore volontairement les `Dockerfile` et le `compose.yaml` — c'est l'exercice laissé aux étudiants. Le repo contenait le code des 3 services applicatifs (vote, worker, result) et des stubs (`compose-sample.yaml`, `worker/Dockerfile-sample`), mais rien de fonctionnel pour lancer le stack complet — valkey et postgres inclus.

**Objectif** : écrire les Dockerfiles des 3 services applicatifs et le fichier Compose du stack complet, pour que `docker compose up` à la racine démarre l'application de vote en local.

**Ce qui a été fait** :

*Travail de l'exercice*

- `.gitignore` : arrêt d'ignorer `Dockerfile` et `compose.yaml`, ce fork les versionne.
- Dockerfiles pour `vote/` (Python), `result/` (Node) et `worker/` (.NET), ce dernier remplaçant le `Dockerfile-sample` fourni.
- `compose.yaml` décrivant les 5 services : valkey, db (postgres), vote, worker, result. Renommé depuis `compose-sample.yaml`, car Compose n'auto-découvre que 4 noms canoniques et `docker compose up` échouait à la racine.

*Durcissement issu des deux passes de revue*

- Healthcheck `pg_isready` sur `db` + `depends_on: service_healthy` sur worker et result, `restart: unless-stopped` sur result, volume nommé `pgdata`.
- Un `.dockerignore` par service.
- Worker passé en multi-stage (image 1,29 Go → 291 Mo) ; result épinglé sur `node:24.19.0-alpine` au lieu de `node:24`, sans `--legacy-peer-deps` ni `--no-optional` ; `WORKDIR` harmonisés sur `/app`.
- `.gitattributes` étendu aux `Dockerfile*` et `*.yaml`/`*.yml` ; `SUIVI.md` et `docker-conventions/SKILL.md` réalignés.
- Deux correctifs dans `vote/` : la boucle de réessai redis, qui ne s'exécutait jamais, et les dépendances Python épinglées.
- Validé : `docker compose config` et `build` OK, démarrage à froid (`down -v` puis `up -d --wait`) avec les 5 services montés, et un vote posté traverse la chaîne jusqu'à une ligne en base.

**Décisions techniques** :

- **Healthcheck ajouté alors que `SUIVI.md` disait l'inverse.** La décision tracée était « le retry applicatif suffit ». Vrai pour le worker, qui boucle indéfiniment ; faux pour `result`, qui abandonne après 3 tentatives et fait `exit(1)`. Au premier démarrage à froid, result perdait la course contre l'`initdb` de postgres et restait mort pendant que vote répondait normalement.
- **`pg_isready -h 127.0.0.1` et pas `pg_isready` seul.** Sans `-h`, la sonde passe par la socket Unix : l'entrypoint postgres y démarre un serveur temporaire qui répond READY alors que le port TCP 5432 refuse encore les connexions. Le healthcheck passait au vert trop tôt.
- **Worker sur `runtime:8.0`, pas `aspnet:8.0`.** `Worker.csproj` est un `Microsoft.NET.Sdk` classique sans package ASP.NET, et son endpoint `/healthz` s'appuie sur `HttpListener` (BCL). Si le projet devient un `Microsoft.NET.Sdk.Web`, il faudra repasser sur `aspnet:8.0`.
- **`.gitattributes` conservé bien qu'aucune renormalisation n'ait été nécessaire.** La revue signalait des fichiers commités en CRLF : faux positif. `git ls-files --eol` confirme du LF, normalisé par `core.autocrlf=true`. Le fichier reste utile — il rend la garantie explicite au lieu de la faire dépendre de la config locale de chaque clone — mais il n'y a pas de dégât historique à corriger.
- **`redis.exceptions.TimeoutError` listé en plus de `ConnectionError`.** Le correctif évident — remplacer le `ConnectionError` nu par celui de redis — restait incomplet : dans redis-py 8.1, `TimeoutError` est un *frère* de `ConnectionError` sous `RedisError`, pas un enfant. N'attraper que le premier laissait passer les dépassements de délai, c'est-à-dire le cas le plus probable quand valkey n'est pas encore prêt. Mesuré contre un redis injoignable : ancienne écriture 6,7 s et zéro tentative, nouvelle 42 s et les cinq tentatives.
- **Versions Python épinglées sur ce qui tourne réellement.** Lues via `pip freeze` dans l'image construite plutôt que choisies : ce sont exactement les versions validées de bout en bout.

---

## #2 — feature/impact-analysis-rule

**Contexte avant** : `feature/dockerfiles` a demandé deux passes du sous-agent `reviewer`, et chaque passe a révélé un problème créé par le correctif précédent. Cas le plus net : `vote` déplacé du port 80 vers 8000 pour tourner en non-root, changement totalement masqué en local par le mapping `ports: "8080:8000"` de compose, et rien d'autre dans le repo n'avait été vérifié. C'est Vincent qui a repéré le manque, pas le workflow.

**Objectif** : inscrire dans `CLAUDE.md` que l'analyse d'impact précède l'action, pour que ce mode de fonctionnement s'applique aux branches suivantes.

**Ce qui a été fait** :

- Nouvelle section « Analyse d'impact avant correctif » dans `CLAUDE.md` : avant tout correctif, balayer le repo pour recenser les autres occurrences de la valeur qui change, les fichiers d'infra (`compose.yaml`, `terraform/`, `k8s/`, pipelines), la documentation qui l'énonce (`README.md`, `SUIVI.md`, `.claude/skills/`), et ce que le changement rend faux ailleurs sans produire d'erreur visible.
- Vérifier qui consomme réellement l'objet modifié avant de conclure, puis regrouper tous les correctifs nécessaires dans un seul commit.
- Ce que l'analyse ne couvre pas doit être écrit en dette (`SUIVI.md` ou fiche de conventions), pas seulement dit en conversation.

**Décisions techniques** :

- **La règle exige de vérifier le consommateur réel, parce que l'inverse avait failli être fait.** La passe `reviewer` signalait comme bloquante l'absence de `WEBSITES_PORT` dans le terraform, après le passage de `vote` sur le port 8000. Or `terraform/terraform.tfvars` pointe `registry_url = https://rgy.k8s.devops-svc-ag.com` et `web_app_vote_docker_image_name = polytech/vote:1.0.1` : c'est l'image préconstruite d'Avisto, la même que celle des manifests `k8s/`, pas celle construite ici. Ajouter `WEBSITES_PORT = "8000"` aurait cassé le déploiement au lieu de le réparer. Le couplage n'existera que le jour où ces variables pointeront une image issue de ce repo.

---

## #3 — feature/container-security

**Contexte avant** : les 3 services tournaient en root (uid 0), aucune directive `USER`. Une première version de cette branche avait été jetée — elle avançait par correctifs successifs, chaque passe de revue révélant le problème créé par la précédente ; c'est de là que vient la règle « Analyse d'impact avant correctif » de l'entrée #2, dont cette branche est la première application.

**Objectif** : faire tourner vote, worker et result en utilisateur non privilégié, en traitant toutes les conséquences dans un seul commit.

**Ce qui a été fait** :

- `USER node` (uid 1000) sur result, `USER app` (uid 1654) sur worker, `RUN useradd` + `USER appuser` sur vote.
- `USER` placé après les `RUN` d'installation, `RUN useradd` au-dessus du `COPY . .` : les dépendances restent possédées par root et la création de l'utilisateur reste une couche stable.
- `ENV PYTHONDONTWRITEBYTECODE=1` sur vote.
- vote passe du port 80 à 8000, `compose.yaml` mappe `8080:8000`, `EXPOSE` déclaré sur les 3 images (8000 / 4000 / 8080).
- `docker-conventions/SKILL.md` : section sécurité réécrite, avec un tableau des consommateurs d'un port de conteneur. `SUIVI.md` : non-root acté, dette conditionnelle terraform écrite.
- Validé : `build` OK et démarrage à froid (`down -v` puis `up -d --wait`) sain, `id` renvoie uid 1000 / 1000 / 1654, `ExposedPorts` conformes, vote et result en 200, un vote posté atteint la base.
- Deux vérifications ajoutées par la passe `reviewer` : `/healthz` du worker répond 200 en non-root — il est lancé en `Task.Run` fire-and-forget dans `Program.cs:26`, donc un échec de bind serait passé inaperçu — et `$HOME` est bien utilisé par gunicorn pour son socket de contrôle, le `--create-home` n'est pas décoratif.

**Décisions techniques** :

- **Réutiliser l'utilisateur non privilégié de l'image de base plutôt que d'en créer un.** `node` et le runtime .NET en fournissent déjà un ; seul `python:3.12-slim` n'en propose aucun, d'où le `useradd` sur vote uniquement.
- **vote quitte le port 80 par déplacement, pas par privilège.** Se lier sous 1024 exige root. Les deux autres options — accorder `CAP_NET_BIND_SERVICE`, ou régler le sysctl `net.ipv4.ip_unprivileged_port_start` — réintroduisent soit un privilège, soit une config d'infra à répliquer sur chaque environnement.
- **`terraform/` et `k8s/` volontairement non modifiés.** L'analyse d'impact confirme qu'ils déploient l'image préconstruite d'Avisto, qui écoute bien sur 80 (détail en entrée #2) ; aucun chemin ne mène l'image buildée ici vers App Service — pas de ressource ACR, pas d'identifiants de registre privé, aucun pipeline dans l'arbre. Dette conditionnelle écrite dans `SUIVI.md` : le jour où ces variables pointeront un build local, `WEBSITES_PORT` devient obligatoire.
- **`PYTHONDONTWRITEBYTECODE=1`, conséquence directe du passage en non-root.** `/app` appartient à root, `appuser` ne peut plus y écrire les `.pyc`, et Python avale l'échec en silence — il recompile à chaque import sans jamais le signaler.
