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

**Contexte avant** : `feature/dockerfiles` a demandé deux passes du sous-agent `reviewer`, et chaque passe a révélé un problème créé par le correctif précédent. Le cas le plus net est venu juste après, sur une première version de `feature/container-security` depuis jetée : `vote` déplacé du port 80 vers 8000 pour tourner en non-root, changement totalement masqué en local par le mapping `ports: "8080:8000"` de compose, et rien d'autre dans le repo n'avait été vérifié. C'est Vincent qui a repéré le manque, pas le workflow.

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

---

## #4 — feature/terraform-conventions-skill

**Contexte avant** : `.claude/skills/` couvrait .NET, Docker et les pipelines Azure DevOps, mais pas Terraform — exclusion volontaire, écrite noir sur blanc dans le `README.md` du dossier. Une fiche `terraform-conventions/SKILL.md`, adaptée de celle du projet `job-finder`, traînait non commitée dans le working tree. Deux choix structurants sur `terraform/` — la région et le nombre d'environnements — n'étaient écrits nulle part, et `SUIVI.md` disait l'inverse de l'un d'eux.

**Objectif** : commiter proprement cette quatrième fiche de conventions et l'indexer, en traitant tout ce que son ajout rend faux ailleurs dans le repo.

**Ce qui a été fait** :

- Décisions #13 (un seul environnement Terraform, `dev`, la séparation dev/prod passant par les deployment slots App Service) et #14 (France Central, jeton `frc`, en remplacement du `westeurope` hérité du repo d'origine) ajoutées à la table de scope de `CLAUDE.md`.
- `SUIVI.md` Sprint 4 corrigé dans le même commit : il prévoyait un `.tfvars` par environnement, soit exactement l'inverse de #13.
- `.claude/skills/terraform-conventions/SKILL.md` : pattern de nommage `{type}-[role-]poly-dev-frc` construit via `local.base_name`, tags obligatoires via `local.tags`, jeton de région dérivé de la location plutôt que saisi à part, pinning des providers et du cœur Terraform, règles de `prevent_destroy`, checklist de revue sécurité et coût, commandes courantes.
- Périmètre resserré par rapport à `job-finder` : pas de landing zone, un seul environnement, dev/prod simulés via deployment slots App Service.
- Trois fichiers énuméraient les fiches existantes et devenaient faux avec cet ajout, tous trouvés par l'analyse d'impact : `.claude/skills/README.md` (index, et Terraform retiré de la liste des stacks volontairement non couvertes), `CLAUDE.md` (section « Conventions par stack ») et `.claude/agents/reviewer.md`, qui liste les fiches que le sous-agent consulte selon la stack du diff.
- Fiche réécrite au prescriptif après trois passes de revue, corps et frontmatter remis d'accord entre eux (détail ci-dessous).
- L'alignement de `terraform/` sur ces conventions vit sur une branche dédiée, `feature/terraform-conventions-apply` : à ce commit, le dossier n'y est pas encore conforme.

**Décisions techniques** :

- **Les décisions #13 et #14 sont posées avant la fiche, pas avec l'alignement de `terraform/`.** Elles étaient d'abord parties sur la branche d'alignement, ce qui paraissait logique — c'est là qu'elles se matérialisent en code. Mais la fiche ne les illustre pas, elle en dépend : c'est #14 qui fixe le jeton `frc` du pattern de nommage, et #13 qui justifie l'environnement verrouillé sur `dev`, et la fiche renvoie explicitement aux deux. Mergée sans elles, elle aurait pointé vers des décisions absentes de `CLAUDE.md`. Le commit qui les trace est donc remonté en tête de branche, avant celui de la fiche.
- **La fiche est écrite au prescriptif, pas au descriptif.** Elle disait « `*.tfstate*`, `*.tfplan` et `.terraform/` sont dans `.gitignore` », « `terraform/` est aligné sur ces conventions », « `minimum_tls_version = "1.2"` (déjà en place) ». C'était vrai tant que la fiche et l'alignement du dossier vivaient dans la même branche ; ça devient faux dès qu'on les sépare. Une fiche mergée seule dans `dev` aurait alors décrit un repo qui n'existe pas — et, plus gênant, aurait fait sauter à ses lecteurs les vérifications qu'elle recommande elle-même : on ne revérifie pas un `.gitignore` qu'une fiche de référence annonce comme déjà correct. Chaque affirmation d'état est devenue une règle à vérifier (« doivent figurer dans `.gitignore` — à vérifier, pas à supposer »), et le paragraphe « État de `terraform/` » a laissé place à la règle intemporelle qu'il illustrait : un renommage n'est gratuit que tant que rien n'est déployé.
- **Le frontmatter a dû être corrigé séparément du corps, et ne l'a été qu'à la deuxième passe.** Son champ `description` annonçait des règles de protection « sur les ressources porteuses de données (Redis, futur Postgres) » alors que le corps de la fiche exclut explicitement le Redis du `prevent_destroy` — c'est une file de messages transitoire, et le protéger ferait échouer le `terraform destroy` de teardown. Le défaut n'est pas cosmétique : la `description` est justement la seule phrase lue, hors contexte, pour décider de charger le skill. Une `description` périmée oriente donc le lecteur avant même qu'il n'atteigne le corps corrigé.

---

## #5 — feature/terraform-conventions-apply

**Contexte avant** : la fiche `terraform-conventions/SKILL.md` venait d'être commitée (entrée #4), mais le dossier `terraform/` hérité du fork ne l'avait jamais respectée et n'avait jamais été relu : noms nus (`rg-terraform`, `vnet`, `asp`), aucun tag, région `westeurope`, aucun artefact Terraform dans le `.gitignore`. Branche rebasée sur `dev` (qui inclut déjà le merge de `feature/terraform-conventions-skill`).

**Objectif** : aligner `terraform/` sur la fiche qui vient d'être écrite, pendant que rien n'est déployé.

**Ce qui a été fait** :

*Alignement et durcissement de la configuration*

- `.gitignore` : `*.tfstate`, `*.tfstate.*`, `*.tfplan`, `.terraform/`, `crash.log` et `crash.*.log`. Posé avant le premier `apply` — aucun state n'a jamais été commité, vérifié sur toutes les branches. `.terraform.lock.hcl` reste versionné, c'est sa raison d'être ; régénéré via `terraform providers lock` pour `windows_amd64` et `linux_amd64`, sans quoi l'agent Linux du futur pipeline y ajouterait son hash à chaque run.
- Nommage `{type}-[role-]poly-dev-frc` construit via `local.base_name`, jamais écrit en littéral ; suffixe d'unicité DNS repoussé en fin de nom. Tags `environment`/`project`/`owner` via `local.tags` sur toutes les ressources Azure dont le type expose l'argument — les 2 subnets et la swift connection ne l'exposent pas côté provider, ce sont les seules sans.
- Variables `project`, `environment` et `owner` ajoutées. Matérialisation des décisions de l'entrée #4 : `environment` verrouillée sur `dev` par validation (#13), `resource_group_location` et `terraform.tfvars` passés à `francecentral` (#14), le jeton `frc` étant dérivé de la location par `local.region_short_by_location`.
- `required_version = "~> 1.9"` et provider `random` déclaré dans `required_providers` — il était résolu implicitement par Terraform, donc non pinné.
- `registry_url` et `web_app_vote_docker_image_name` perdent leur `default = ""` : une valeur vide ne fait pas échouer le `plan`, App Service retombe silencieusement sur Docker Hub et la panne n'apparaît qu'au pull du conteneur. Validations ajoutées sur le schéma `https://` et sur la présence d'un tag d'image explicite, non vide et différent de `latest`.

*Correctifs issus des passes de revue*

- Redis fermé sur Internet : `public_network_access_enabled = false`. Le provider le laisse à `true` par défaut, donc le cache était joignable de n'importe où sur 6380 avec la seule clé, pendant qu'un private endpoint et une zone DNS privée étaient provisionnés pour lui.
- `azurerm_private_dns_a_record` supprimée au profit d'un bloc `private_dns_zone_group` sur le private endpoint : c'est Azure qui crée et maintient l'enregistrement.
- `vnet_route_all_enabled = true` sur la Web App. `vnet_image_pull_enabled` reste à `false` : le pull d'image continue de passer hors VNET, le registre public d'Avisto reste joignable.
- Validé : `terraform fmt -check`, `validate` et `plan` passent — 12 objets à créer, 0 à détruire, noms conformes au pattern vérifiés dans la sortie du plan. Rien n'est déployé sur Azure.
- Dette écrite dans `SUIVI.md`, volontairement hors scope : la clé Redis est injectée en clair dans les `app_settings`, donc en clair dans le state. Cible propre, Key Vault + identité managée. Le risque est réduit — state gitignoré, cache non exposé, la clé seule ne suffit plus à l'atteindre — pas supprimé.

**Décisions techniques** :

- **Renommage intégral assumé parce que rien n'est déployé.** Changer le `name` d'une ressource Azure force son remplacement. Le state est vide, le renommage ne coûte donc rien — et c'est précisément la raison de le faire maintenant plutôt que plus tard : après un premier `apply`, ça devient une tâche dédiée, jamais un aparté.
- **Le jeton de région est dérivé de la location, pas saisi dans une seconde variable.** Deux champs à tenir en phase à la main finissent par diverger, et une infra nommée `-frc` réellement déployée en `westeurope` ne se rattrape que par recréation complète. Le coût de l'inversion est asymétrique : ajouter une région sans l'ajouter à la table fait échouer le `plan` sur un index manquant — bruyant, donc sans danger. C'est aussi pourquoi la liste autorisée de `resource_group_location` reste plus large que la décision #14, à la différence de `environment` verrouillée sur une valeur : elle garantit l'existence d'un jeton de nommage, pas le respect de la décision.
- **Fermer l'accès public au Redis imposait deux corrections couplées, invisibles au `plan`.** La ligne `public_network_access_enabled = false` seule aurait cassé le vote au runtime avec un plan parfaitement propre. Le point non évident : l'intégration VNET régionale route les destinations RFC1918, mais **pas la résolution DNS de l'app**. Sans `vnet_route_all_enabled = true`, la Web App résout le nom du cache hors du VNET, donc hors de la zone privatelink, et tombe sur l'IP publique qu'on venait de fermer.
- **L'enregistrement DNS A a été supprimé plutôt que corrigé.** Il recevait `redis.hostname`, donc le FQDN complet, alors que `zone_name` fournit déjà le domaine — il produisait `xxx.redis.cache.windows.net.privatelink.redis.cache.windows.net`. Le correctif évident était de lui passer le seul label d'hôte, mais le provider n'expose que le FQDN : écrire ce record à la main revient toujours à en redécouper le label, et la faute reviendra. Déléguer à `private_dns_zone_group` fait partir la classe d'erreur avec la ressource, et l'enregistrement suit l'IP du private endpoint si elle change. Cette suppression sèche n'est gratuite que parce que rien n'est déployé : avec un state existant, elle aurait orphelinné l'enregistrement côté Azure et imposé un `terraform state rm`.
- **Le pin `required_version` est commité avant les validations qui en dépendent.** L'ordre des commits n'est pas cosmétique ici : `startswith()`/`endswith()` sont apparus en 1.3, un garde-fou posé après leur introduction laisserait une fenêtre où un agent CI sur une version plus ancienne échoue de façon cryptique. Le plancher est posé à 1.9 et non 1.3, pour laisser la place à la validation croisée entre variables, attendue dès l'arrivée des App Services worker et result.

---

## #6 — feature/worker-testability

**Contexte avant** : `worker/` ne portait aucun test — sa seule logique isolable, l'interprétation du JSON déposé dans la file par le front `vote`, était enfermée dans un type anonyme déclaré dans `Main`, donc inaccessible depuis un test. Son endpoint `/healthz` était démarré après `OpenDbConnection` et `OpenRedisConnection`, deux boucles qui bloquent indéfiniment tant que leur cible ne répond pas. Cette branche est l'une des trois issues du découpage de `feature/azure-pipeline`, qui combinait à l'origine tests worker, infra Terraform et pipeline CI ; les deux autres parties vivent sur des branches séparées, mergées après celle-ci.

**Objectif** : rendre le worker testable et sûr à déployer — extraire le parsing du vote derrière un point d'entrée public, le couvrir de tests, et corriger l'ordre de démarrage qui masque le port de santé.

**Ce qui a été fait** :

- `JsonConvert.DeserializeAnonymousType` sur un type anonyme dans `Main` devient `ParseVote(string)` + classe `VotePayload`, tous deux publics.
- Projet `worker.Tests/` (xUnit), placé à côté de `worker/` et non dedans. Quatre cas sur `ParseVote` : charge utile nominale, champ inconnu ignoré, champ manquant, JSON illisible — les deux derniers documentent le comportement réel du worker (vote perdu silencieusement), pas le comportement souhaitable.
- `StartHealthCheckServer` déplacé avant l'ouverture des connexions DB et Redis : le port de santé est désormais lié dès le démarrage, plus après que les dépendances aient répondu.
- `bin/` et `obj/` ajoutés au `.gitignore` racine — le projet de test les fait apparaître à la racine du worker.
- `SUIVI.md` : case « Tests unitaires de base » du Sprint 2 cochée, deux dettes tracées — validation du `voter_id` manquant, distinction liveness/readiness sur `/healthz`.
- Validé en local : 4 tests, 4 succès.

**Décisions techniques** :

- **Le projet de test vit à côté de `worker/`, pas dedans.** `worker/Dockerfile` fait `COPY . .` depuis ce dossier ; un projet de test placé dedans se serait retrouvé embarqué dans l'image de production avec ses dépendances.
- **`RollForward=LatestMajor` sur `Worker.Tests.csproj`.** Sans lui, `dotnet test` échoue au lancement du testhost sur toute machine où seul un SDK/runtime .NET plus récent que 8.0 est installé, avec un message qui ne pointe pas vers le code (« You must install or update .NET »). Le `build` seul ne révèle pas le problème, lui passe déjà sans cette ligne.
- **Les tests assertent le comportement réel, pas le comportement souhaitable.** Un `voter_id` absent passe en base tel quel, un JSON illisible arrête le worker après que le message a déjà été retiré de la file — le vote est perdu silencieusement. Écrire ces cas à l'envers, en asserant ce qu'on voudrait, aurait fait échouer la suite sur du code que cette branche ne corrige pas. Dette tracée dans `SUIVI.md` (Sprint 2), pas seulement en commentaire.
- **Les noms de champs JSON restent en snake_case côté contrat, PascalCase côté C#, réconciliés par des attributs `JsonProperty`.** Le contrat de la file appartient au front `vote/app.py`, la convention de nommage au projet worker — aligner l'un sur l'autre plutôt que de les faire cohabiter aurait fait dépendre un service de la convention de l'autre.
- **Le worker se déclare vivant dès le démarrage, pas prêt.** Corriger l'ordre de bind ne distingue pas liveness et readiness : il répond 200 alors qu'il attend peut-être encore sa base. Les distinguer demande un état partagé entre la boucle de traitement et le listener HTTP — tracé en dette (Sprint 2) plutôt que traité ici, pour rester sur le seul correctif qui rendait le port injoignable.

---

## #7 — feature/terraform-worker-infra

**Contexte avant** : `feature/worker-testability` (entrée #6) vient d'être mergée dans `dev` — le worker est testable, mais `terraform/` n'héberge toujours que le front `vote` et le Redis, hérités du fork : aucun registre de conteneurs, aucune base Postgres, aucun App Service pour le worker, aucun backend d'état distant. C'est la 2e des trois branches issues du découpage de `feature/azure-pipeline` ; la 3e (pipeline Azure DevOps) n'existe pas encore et consommera ce que celle-ci expose.

**Objectif** : écrire tout le volet Terraform nécessaire pour héberger le worker sur Azure — registre de conteneurs, Postgres privé, App Service, backend d'état distant sur Azure Storage — et exposer en sortie ce qu'un futur pipeline CI devra lire, sans encore écrire ce pipeline.

**Ce qui a été fait** :

- `terraform-conventions/SKILL.md` : suppression du renvoi à « une branche dédiée » pour l'alignement de `terraform/`, cette branche (entrée #5) étant mergée depuis — la phrase était devenue une note historique dans un document censé faire référence en continu.
- Correction de la clé Redis non url-encodée dans la connection string du vote : un `/` de clé base64 tronquait le `netloc`, panne intermittente selon le tirage de la clé à chaque recréation du cache.
- ACR (SKU Basic, `admin_enabled = false`, accès public) pour l'image du worker — registre distinct de `vote_registry_url`, qui reste celui d'Avisto.
- Postgres Flexible Server en accès privé (sous-réseau dédié et délégué + zone DNS privée), pour stocker les votes.
- App Service (Linux, conteneur) pour le worker sur le plan B1 existant, sans deployment slot.
- `CLAUDE.md` (décisions #11, #13) et `terraform-conventions/SKILL.md` réalignés sur « pas de slots » et sur les mécanismes réellement posés (Postgres via sous-réseau délégué, ACR public en Basic), pendant la branche plutôt que dans celle du pipeline comme prévu au départ.
- Backend d'état déplacé sur un Storage Account Azure, hors du resource group géré par cette configuration, avec import du resource group existant.
- Sorties Terraform (resource group, registre et son serveur de connexion, App Service du worker, URL du vote, FQDN privé de Postgres) pour un futur stage `Infra` du pipeline CI.
- `azurerm_app_service_virtual_network_swift_connection` (utilisé par le vote) supprimée au profit de `virtual_network_subnet_id` sur chaque App Service, vote compris : le provider interdit de mélanger les deux mécanismes dès qu'un `virtual_network_subnet_id` apparaît sur une des apps du même plan.
- Validé : `plan` propre, 19 objets à créer, 0 à modifier, 0 à détruire — le zéro modification confirme que le resource group importé à la main correspond à la configuration. Rien n'est déployé sur Azure au sens applicatif, seuls le resource group et le backend d'état ont été amorcés.

**Décisions techniques** :

- **Postgres privé par sous-réseau délégué, pas par private endpoint comme le Redis.** Un serveur flexible ne se met pas derrière un private endpoint : il exige un sous-réseau dédié et délégué, distinct de celui du cache, et sa propre zone DNS privée au nom libre (contrairement à la zone privatelink imposée pour Redis). Les deux ressources « privées » du projet suivent donc des mécanismes différents, pas une incohérence.
- **Pas de `prevent_destroy` sur le serveur Postgres, alors que la fiche de conventions le prévoyait.** Les votes sont des données de démonstration régénérables ; protéger le serveur contaminerait le resource group entier et bloquerait le `terraform destroy` de teardown, le levier de coût principal du projet. La fiche est corrigée dans le même commit plutôt que contredite en silence. `prevent_destroy = false` reste posé explicitement sur la base, parce que le provider en pose un implicite sur ce type de ressource.
- **ACR avec `admin_enabled = false` et pull par identité managée.** L'utilisateur admin distribuerait un couple identifiant/mot de passe partagé, à stocker dans les `app_settings` — donc en clair dans le state. Sans secret de registre, les App Services tirent leurs images par identité managée et l'agent de pipeline par sa connexion de service ; en contrepartie l'attribution du rôle `AcrPull` exige d'écrire des assignations de rôle, que `Contributor` ne couvre pas — d'où un rôle `User Access Administrator` supplémentaire à donner à la connexion de service, tracé dans `SUIVI.md`.
- **ACR volontairement public malgré la checklist sécurité de la fiche.** Le SKU Basic ne supporte pas les private endpoints (il faudrait Premium, ~4x le coût du reste de l'infra), et l'agent Microsoft-hosted du pipeline est hors VNET — un registre fermé serait injoignable au push. `admin_enabled = false` fait qu'atteindre le registre ne suffit pas : il faut un jeton Entra ID et un rôle dessus.
- **App Service du worker sur le port 8080 avec un chemin de health check terminé par un slash, différent du port 8000 du vote.** App Service recycle tout conteneur Linux qui ne répond sur aucun port ; le worker n'est pas une app web mais expose `/healthz` sur 8080. `WEBSITES_PORT = "8080"` et `health_check_path` évitent qu'une sonde sur le port 80 par défaut ne renvoie 502 sur une application saine. Le slash final suit le préfixe `HttpListener` réellement enregistré côté worker.
- **`ignore_changes` sur `docker_image_name` de l'App Service worker.** Le tag déployé appartient au pipeline (`$(Build.BuildId)` à chaque run) ; sans cette ligne, le `terraform apply` suivant ramènerait l'app à la valeur figée du `.tfvars` et annulerait silencieusement le dernier déploiement.
- **Backend d'état hors du resource group géré, dans `rg-tfstate-poly-dev-frc`.** Le teardown du projet détruit `rg-poly-dev-frc` et tout son contenu ; y loger le state reviendrait à l'effacer en cours de destruction, en laissant l'infra à moitié détruite et plus rien pour finir le travail. Amorcé à la main (`az group create`/`storage account create`/`storage container create`) car Terraform ne peut pas créer le stockage où il écrit son propre state ; `use_azuread_auth = true` évite tout secret de compte à stocker, au prix d'un rôle `Storage Blob Data Contributor` à donner en plus au service principal. `resource_provider_registrations = "none"` pour la même logique : par défaut le provider énumère les resource providers de l'abonnement, hors de portée d'un principal scopé aux seuls resource groups du projet — le stage échouerait avant la première ressource, sur un message qui ne parle pas de droits manquants.
- **Sorties du registre et de l'App Service non recopiées dans un groupe de variables du pipeline.** Leurs noms portent un suffixe `random_string` tiré à chaque création ; une valeur figée à la main serait périmée dès le premier cycle destroy/apply, qui est la routine de ce projet entre deux sessions de travail. Le futur stage `Infra` les lit donc directement en sortie de `plan`/`apply`.
- **Décision #11 (pas de slots) réalignée dans `CLAUDE.md` au milieu de la branche, pas à la fin.** Les commits précédents (App Service, `SUIVI.md`) affirmaient déjà la révision de la décision ; la laisser non corrigée dans le document qui fait foi jusqu'au commit du pipeline aurait fait vivre `terraform/` en avance sur la décision qu'il matérialise. Seul le retrait des slots est acté ici — la question de l'approbation manuelle avant déploiement reste ouverte pour la branche du pipeline.

---

## #8 — feature/azure-pipeline-ci

**Contexte avant** : `feature/terraform-worker-infra` (entrée #7) vient d'être mergée dans `dev` — le worker a son registre (ACR), son Postgres privé, son App Service et des sorties Terraform prêtes à être lues, mais rien ne les consomme : aucun pipeline n'existe encore. C'est la 3e et dernière des branches issues du découpage de `feature/azure-pipeline`.

**Objectif** : écrire le pipeline Azure DevOps qui build, teste, publie l'image du worker dans l'ACR et la déploie sur l'App Service, en consommant les sorties Terraform exposées par la branche précédente (décisions #10/#11 de `CLAUDE.md`).

**Ce qui a été fait** :

- `azure-pipelines.yml` : cinq stages `Build → Test → Infra → Publish → Deploy`. `Build`/`Test` compilent et testent le worker (.NET 8, cache NuGet). `Infra` fait `terraform plan` sur toute PR, `apply` seulement au merge, puis republie resource group / ACR / App Service en variables de pipeline via `terraform output`. `Publish` construit et pousse l'image dans l'ACR. `Deploy` la déploie sur l'App Service du worker.
- Déclencheurs filtrés sur `worker/*`, `worker.Tests/*`, `terraform/*` et le YAML lui-même — un commit qui ne touche aucun de ces chemins ne relance rien.
- Périmètre limité au worker : vote et result restent déployés depuis le registre d'Avisto (décision #3), rien à industrialiser côté DevOps.
- Groupe de variables `polytech-training-dev` réduit à une seule entrée, `azureServiceConnection` — les quatre noms de ressources ne s'y trouvent pas, ils viennent de `terraform output` à chaque run.
- `.gitignore` : ajout de `tfplan`/`tfplan.*`, motif que `*.tfplan` ne couvrait pas ; fiches `azure-pipelines-conventions` et `terraform-conventions` mises à jour pour documenter les deux écarts assumés du projet (pas d'artefact `.NET` entre stages, pas de deployment slots) plutôt que de les laisser contredire la fiche en silence.
- `CLAUDE.md`, décision #11 complétée : stage `infra` ajouté à la liste, et retrait de l'approbation manuelle avant déploiement (le retrait des slots avait déjà été acté dans l'entrée #7).
- `SUIVI.md` : Sprint 3 coché, checklist de configuration manuelle Azure DevOps à faire avant le premier run (groupe de variables, environnement `polytech-training-dev`), dette tracée — trigger `main` sur un state unique partagé avec `dev`, `Npgsql` 4.1.9 signalé vulnérable (NU1903), `/healthz` qui déclare la vivacité et pas la disponibilité.
- Rien n'a encore tourné : le YAML est commité, mais le projet Azure DevOps, la connexion de service `arm-poly-dev`, le groupe de variables et l'environnement `polytech-training-dev` restent à créer côté portail avant le premier run — pas de validation en conditions réelles sur cette branche.

**Décisions techniques** :

- **Aucune approbation manuelle avant déploiement — la question laissée ouverte par l'entrée #7 est tranchée ici.** Le pipeline est bâti sur le postulat que le merge sur `dev` *est* la décision : une PR affiche le `terraform plan` sans rien créer, le merge applique, publie et déploie sans jugement humain supplémentaire. Une approbation resterait possible depuis l'interface Azure DevOps sur l'environnement `polytech-training-dev`, mais rien ne l'exige, et elle ne couvrirait de toute façon que le stage `Deploy` — pas le `terraform apply` du stage `Infra`, qui peut pourtant remplacer ou détruire des ressources et n'a pas d'`environment:` du tout.
- **Le plan appliqué est celui écrit sur disque (`-out=tfplan`), jamais recalculé.** `apply tfplan` rejoue exactement ce que la PR a montré ; un `apply` qui replanifie pourrait exécuter autre chose si l'infra a bougé entre les deux étapes. Les stages qui produisent ou déploient (`Publish`, `Deploy`, et le pas `apply` d'`Infra`) portent en plus une garde `Build.Reason != PullRequest` : sans elle, une PR pousserait une image et déploierait depuis une branche que personne n'a relue.
- **`addSpnToEnvironment` suivi d'une recopie manuelle vers les variables `ARM_*`.** La tâche `AzureCLI@2` connecte le CLI `az`, pas le provider `azurerm` de Terraform ; sans cette recopie, `terraform init`/`plan` échouent faute d'authentification alors que `az` fonctionne.
- **`az acr build` plutôt que `Docker@2`.** Le projet n'a qu'une connexion de service, de type ARM ; `Docker@2` en exigerait une seconde, de type Docker Registry, avec ses propres identifiants à maintenir. Le build s'exécute côté registre, sans démon Docker sur l'agent.
- **Aucun artefact `.NET` transporté entre `Build` et `Publish`.** Ce qui est réellement déployé est une image de conteneur, reconstruite au stage `Publish` depuis `worker/Dockerfile` — celui du `docker compose` local, pour ne pas faire diverger l'image vérifiée en local de celle déployée. C'est une redite assumée de la compilation du stage `Build`, tracée dans `SUIVI.md`. Le stage `Build` restaure les deux `.csproj` (worker et tests) pour que la clé du cache NuGet couvre ce qu'elle annonce ; sinon `Test` obtient un *hit* sur cette clé qu'il ne peut jamais compléter et retélécharge ses paquets à chaque run.

---

## #9 — feature/pr-workflow-docs

**Contexte avant** : `azure-pipelines.yml` (entrée #8) est conçu depuis son premier commit autour d'une PR GitHub — plan Terraform en preview sur la PR, `apply` déclenché au merge. La règle de branching de `CLAUDE.md` disait l'inverse : pas de PR, merge local direct sur `dev`, une simplification posée pour la vitesse du week-end avant l'entretien, jamais réconciliée avec le pipeline une fois celui-ci écrit — Vincent a découvert l'incohérence en testant le pipeline pour de vrai, un push direct sur `dev` ayant enchaîné `plan` et `apply` sans aucune preview.

**Objectif** : faire concorder la règle de branching documentée avec la façon dont le pipeline a réellement été conçu.

**Ce qui a été fait** :

- `CLAUDE.md` : règle de branching réécrite — PR GitHub obligatoire entre `feature/*` et `dev`, merge via le bouton GitHub en stratégie "Create a merge commit", règle explicite "aucun commit direct sur `dev`/`main`, sans exception". Section Hook Git mise à jour : `.githooks/pre-merge-commit` devient un vestige, les branches étant désormais protégées côté GitHub. Nouvelle section "Protection des branches (GitHub)".
- Protection de branche appliquée pour de vrai via l'API GitHub (`gh api`) sur `dev` et `main` : PR obligatoire, push direct et force-push refusés, `enforce_admins` actif — s'applique même à l'administrateur du repo.
- Réglages de merge du repo modifiés via l'API GitHub : squash et rebase merge désactivés, seul "Create a merge commit" reste possible.
- `.claude/agents/reviewer.md` et `.claude/agents/docwriter.md` : frontmatter et corps alignés sur le nouveau vocabulaire (push/PR au lieu de merge local).
- Une passe de `reviewer` a trouvé deux points bloquants — contradiction interne entre "aucune exception" et la justification du hook, affirmation fausse sur l'affichage systématique du plan Terraform dans toute PR alors que le pipeline filtre par chemin — et deux avertissements — incohérence de vocabulaire entre les deux agents, règle de merge strategy non vérifiée mécaniquement au premier passage. Les quatre corrigés dans le même commit, après vérification réelle (lecture de `azure-pipelines.yml`, requêtes `gh api` sur l'état effectif des branch protections et des réglages de merge du repo).

**Décisions techniques** :

- **Protection de branche appliquée par API plutôt que documentée comme consigne.** Le hook `pre-merge-commit` reposait sur une discipline de workflow que Claude Code pouvait respecter, mais que rien n'empêchait de contourner par un `git push` direct hors de ses outils — c'est précisément ce qui venait de se produire : un commit avait atterri directement sur `dev` par erreur pendant ce travail, repéré et déplacé sur cette branche avant tout push. La règle "aucun commit direct sur `dev`/`main`" ne devient un vrai filet que si GitHub lui-même la fait respecter — d'où `enforce_admins`, qui s'applique même à Vincent en tant qu'administrateur du repo.
- **Squash et rebase merge désactivés au niveau du repo, pas seulement évités en pratique.** L'historique Git propre, commit par commit en Conventional Commits, est un artefact de démonstration explicite du projet (voir `CLAUDE.md`, « distinguer fork initial → phase de compréhension → mes ajouts ») — des entrées de ce journal s'appuient sur la survie de commits individuels après merge (entrée #4 : « le commit qui les trace est donc remonté en tête de branche » ; entrée #5 : « le pin `required_version` est commité avant les validations qui en dépendent »). Un squash merge aurait aplati chaque branche en un seul commit et effacé cette granularité.
- **Le hook `.githooks/pre-merge-commit` reste en place plutôt que d'être supprimé.** Il n'a plus de chemin d'exécution réel — la protection GitHub bloque tout push direct avant qu'un `git merge` local n'ait la moindre chance de s'exécuter contre `dev` — mais le supprimer effacerait la trace de la démarche (hook local → protection GitHub) sans bénéfice, pour un fichier qui ne coûte rien à laisser en vestige documenté.
