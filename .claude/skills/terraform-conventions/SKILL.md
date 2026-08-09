---
name: terraform-conventions
description: Conventions Terraform du projet polytech-training — nommage Azure (rg-poly-dev-frc, asp-poly-dev-frc...), tags, règles de lifecycle/protection et pourquoi ce projet n'en pose aucune (Postgres compris), checklist sécurité et coût, commandes courantes. Utilise ce skill avant d'écrire ou modifier tout fichier .tf, de créer une resource group / ressource Azure, de nommer une ressource, ou de reviewer un diff touchant terraform/ — même si l'utilisateur ne dit pas explicitement "convention" ou "Terraform". Adapté depuis les conventions terraform du projet job-finder ; nomenclature ajustée au périmètre plus restreint de ce projet (pas de landing zone, un seul environnement, pas de deployment slots).
---

# Conventions Terraform — projet polytech-training

Ces règles sont adaptées de celles du projet `job-finder` et resserrées sur ce périmètre : pas de landing zone, un seul environnement, pas de deployment slots (décision #11 de `CLAUDE.md`).

Elles décrivent la cible, pas nécessairement l'état courant de `terraform/`. Vérifier le code avant de supposer qu'une règle y est déjà appliquée — c'est vrai en permanence, pas seulement au moment où cette fiche a été écrite.

## Nommage

- Cloud provider : Azure only.
- Pattern de nommage : `{type}-{role?}-{project}-{environment}-{region}-{index?}`
  - Projet : `poly`
  - Environnement : `dev` (un seul environnement, cf. `CLAUDE.md` décision #13 — pas de séparation dev/prod, ni par `.tfvars` ni par deployment slots)
  - Région : `frc` (France Central, cf. `CLAUDE.md` décision #14)
  - Rôle : optionnel, quand plusieurs ressources du même type se distinguent par leur **rôle** et non par un compteur. `snet-platform-poly-dev-frc` et `snet-asp-poly-dev-frc` restent lisibles là où `snet-poly-dev-frc-1` / `-2` ne dit plus rien.
  - Index : optionnel, seulement quand plusieurs instances du même type sont réellement interchangeables. Role et index ne s'utilisent pas ensemble.
  - Préfixes : `rg`, `vnet`, `snet`, `pe` (Private Endpoint), `pdnsl` (Private DNS Zone Virtual Network Link), `asp` (App Service Plan), `app` (Web App), `redis`, `acr`, `psql`, `appi` (Application Insights)
  - Exemples : `rg-poly-dev-frc`, `asp-poly-dev-frc`, `snet-platform-poly-dev-frc`, `pe-redis-poly-dev-frc`
  - **Noms imposés par Azure** : certaines ressources n'ont pas de nom libre et sortent du pattern. `azurerm_private_dns_zone` doit porter exactement le nom de zone privatelink du service (`privatelink.redis.cache.windows.net`) — le renommer casse la résolution. Vérifier avant de « corriger » un nom qui ne suit pas le pattern.
  - Contraintes de longueur/charset spécifiques à certains types — **vérifier la doc du type avant de nommer**, elles ne sont pas uniformes :
    - Storage account : 3-24 caractères, alphanumérique minuscule, **pas de tiret** → `stpolydevfrc`
    - Container Registry : 5-50 caractères, alphanumérique, **pas de tiret** → `acrpolydevfrc`
  - Ressources nécessitant un nom globalement unique sur Azure (Redis, Web App, ACR...) : un suffixe aléatoire (`random_string`) se place **en fin de nom**, après la région — `redis-poly-dev-frc-a1b2c`. Il joue le rôle d'unicité DNS, pas de compteur d'instances.

**Le nom ne s'écrit jamais en littéral.** Les exemples ci-dessus montrent le résultat, pas ce qu'on tape. Toute nouvelle ressource se déclare ainsi :

```hcl
name = "asp-${local.base_name}"          # ou "app-worker-${local.base_name}" avec un rôle
tags = local.tags
```

`local.base_name` concatène projet, environnement et jeton de région ; `local.tags` porte les trois tags obligatoires. Les deux se déclarent dans un bloc `locals` en tête de `main.tf`. Recopier `poly-dev-frc` à la main réintroduit exactement la divergence que ces locals suppriment.

Le jeton de région se **dérive** de `resource_group_location`, il ne se saisit jamais à part. Changer de région impose donc de toucher **deux** endroits, dans le même commit :
1. le `contains([...])` de la validation de `resource_group_location` (`variables.tf`)
2. la table `local.region_short_by_location` (`main.tf`)

Oublier le 2ᵉ fait échouer le plan sur un index manquant — bruyant, donc sans danger. C'est l'inverse (deux variables indépendantes) qui produirait une infra nommée `-frc` déployée ailleurs.

**Un renommage n'est gratuit que tant que rien n'est déployé.** Changer le `name` d'une ressource Azure force son remplacement. Sur un state vide, le renommage ne coûte rien ; après un premier `apply`, il devient destructif et se traite comme une tâche dédiée, jamais en aparté d'un autre correctif.

## Séparateurs de section dans les fichiers `.tf`

```hcl
# ==============================================================================
# Nom de la section
# ==============================================================================
```

## Règles

- Chaque ressource **supportant l'argument `tags`** doit porter `environment`, `project`, `owner`. Tous les types azurerm ne l'exposent pas : `azurerm_subnet` et `azurerm_app_service_virtual_network_swift_connection` n'en ont pas (ils héritent du contexte de leur parent). Leur absence de tags n'est pas un écart — en ajouter est une erreur de `plan`.
- Chaque bloc `variable` et `output` doit avoir une `description`. Sans exception.
- Ajouter des blocs `validation` sur les variables avec des contraintes évidentes (valeurs acceptées, formats attendus). Ne pas valider un champ libre (`name`) — Azure le valide lui-même à l'apply. `location` fait exception **sur ce projet** : il alimente `local.region_short_by_location`, donc la liste des valeurs acceptées est une vraie contrainte interne, pas une redite d'Azure.
- Tout ce dont le code dépend pour fonctionner se pin : les providers dans `required_providers`, et le cœur Terraform dans `required_version`. Une CI qui tourne sur une version non pinnée échoue de façon cryptique le jour où l'agent est mis à jour.
- Dès qu'un module est introduit (prévu Sprint 4 si le projet grandit), référencer les ressources via leurs outputs de module, jamais directement (`module.rg.name`, pas `azurerm_resource_group.rg.name`).
- Tout provider utilisé, directement ou via un module, doit être déclaré explicitement dans `required_providers`.
- **Le state ne se versionne jamais.** `*.tfstate*`, `*.tfplan` et `.terraform/` doivent figurer dans `.gitignore` — à vérifier, pas à supposer. Le state stocke en clair tout ce que les providers remontent — ici `azurerm_redis_cache.primary_access_key`, injectée dans les `app_settings` de la Web App. `.terraform.lock.hcl` fait exception : il se commit, il fige les versions de providers.
- `terraform.tfvars` ne doit jamais être commit s'il contient des secrets. Celui de ce projet ne contient que des valeurs non sensibles (URL de registre public, location, tag d'image) : son tracking est un choix assumé, pas un oubli. Dès qu'une valeur sensible y entre, il sort du suivi Git.
- Une fois le pipeline Azure DevOps en place (Sprint 3) : `terraform apply` passe par la CI, pas en local — évite un state local divergent du state distant. Avant ça, applies locales tolérées le temps du bootstrap initial.

## Commandes courantes

```bash
terraform init
terraform fmt
terraform fmt -check      # utilisé en CI
terraform validate
terraform plan -input=false
terraform apply -input=false
```

## Règles de lifecycle sur les ressources critiques

`prevent_destroy = true` protège les données **irremplaçables**. Le critère n'est pas « cette ressource stocke », c'est « reperdre ce qu'elle contient coûte cher ».

**Aucune ressource de `terraform/` ne remplit ce critère, `azurerm_postgresql_flexible_server` compris, et le dossier ne contient donc aucun `prevent_destroy`.** C'est un choix, pas un oubli — sur un projet de démonstration, la protection coûte plus qu'elle ne rapporte.

- `azurerm_postgresql_flexible_server` — c'est la seule ressource qui stocke durablement, et elle reste non protégée. Les votes qui y vivent sont des données de démonstration, régénérables en une minute par le front. Le poser interdirait le `terraform destroy` de teardown, principal levier de coût du projet, pour préserver quelque chose qui ne vaut rien. Le jour où le projet porte des données réelles, cette ligne est la première à changer.
- `azurerm_resource_group` — le protéger bloquerait à la fois un renommage de ressource et le teardown, alors que détruire l'infra entre deux sessions est le levier de coût principal (cf. checklist ci-dessous). Le RG ne porte aucune donnée par lui-même.
- `azurerm_redis_cache` — c'est une **file de messages transitoire**, pas un stockage : les votes y passent quelques millisecondes avant que le worker ne les écrive en Postgres. Rien à protéger.
- `azurerm_container_registry` — il ne contient que des images reconstructibles par le pipeline à partir du dépôt Git. Perdre le registre coûte un run de pipeline.

Attention à un piège du provider, distinct de la règle ci-dessus :
`azurerm_postgresql_flexible_server_database` porte un `prevent_destroy = true` **implicite**. Sans un bloc `lifecycle { prevent_destroy = false }` explicite, le `terraform destroy` échoue au plan — et le message ne dit pas d'où vient la protection.

Deux pièges à garder en tête avant de poser un `prevent_destroy` :
- il interdit aussi les changements qui **forcent un remplacement** (renommage inclus) — le poser sur une ressource dont le nom n'est pas stabilisé, c'est se bloquer soi-même ;
- il **contamine tout le resource group** : protéger une seule ressource suffit à faire échouer le `terraform destroy` complet.

## Checklist de revue sécurité et coût

- Pas d'IP publique sans justification explicite dans le message de commit/PR.
- Aucun secret ou mot de passe en clair dans le code Terraform (utiliser des variables, jamais de valeur hardcodée).
- Vérifier `.gitignore` avant tout premier `apply` sur une nouvelle machine : un state non ignoré est la fuite de secret la plus banale d'un projet Terraform.
- **Toute ressource PaaS dotée d'un private endpoint doit avoir `public_network_access_enabled = false`.** Les providers laissent l'accès public ouvert par défaut : sans cette ligne, le private endpoint est décoratif et la ressource reste joignable depuis Internet avec sa seule clé. Vaut pour Redis. Postgres suit le même principe par un mécanisme différent — un serveur flexible ne se met pas derrière un private endpoint, l'accès privé passe par un sous-réseau délégué. L'ACR, lui, reste volontairement public : le SKU Basic ne supporte pas les private endpoints (Premium serait ~4x le coût), justifié en commit.
- **Fermer l'accès public va toujours par paire avec `vnet_route_all_enabled = true`** sur les App Services qui consomment la ressource. L'intégration VNET régionale route déjà les destinations RFC1918 par défaut, mais **pas la résolution DNS** : sans ce réglage (défaut du provider : `false`), l'app résout le nom public de la ressource hors du VNET, tombe sur son IP publique qu'on vient de fermer, et casse — alors que `terraform plan` ne voit rien. `route_all` étend le routage à `0.0.0.0/0` et fait passer le DNS par le VNET, donc par les zones privatelink qui y sont liées.
  - Ne pas confondre avec `vnet_image_pull_enabled` : laissé à `false`, le pull de l'image continue de passer par le réseau d'infrastructure App Service. C'est ce qui permet de garder un registre public joignable tout en routant le reste par le VNET.
- Azure Cache for Redis : `minimum_tls_version = "1.2"`.
- Signaler toute ressource générant un coût récurrent significatif ; proposer une alternative moins chère si pertinent (ex. SKU Basic plutôt que Standard tant que le projet est en démo/apprentissage).
- Projet de démo : `terraform destroy` entre deux sessions de travail est le levier de coût principal. Ne rien poser qui l'empêche sans raison (cf. `prevent_destroy` ci-dessus).
- Connexions de service (SP Azure DevOps) : scope au resource group du projet, jamais à toute la subscription — si le scope n'a pas pu être restreint immédiatement, la dette se trace dans `SUIVI.md`.
