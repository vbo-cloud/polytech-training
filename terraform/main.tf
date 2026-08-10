# ==============================================================================
# Locals — naming and tags
# ==============================================================================
# Pattern de nommage : {type}-{role?}-{project}-{environment}-{region}-{index?}
# cf. .claude/skills/terraform-conventions/SKILL.md
locals {
  # Le jeton de région est *dérivé* de la location, jamais saisi séparément :
  # deux champs à tenir en phase à la main finiraient par diverger, et une infra
  # nommée `-frc` déployée en `westeurope` ne se rattrape que par recréation
  # complète. Les clés doivent rester alignées sur la validation de
  # `resource_group_location` dans variables.tf.
  region_short_by_location = {
    francecentral = "frc"
    westeurope    = "weu"
    northeurope   = "neu"
  }

  base_name = "${var.project}-${var.environment}-${local.region_short_by_location[var.resource_group_location]}"

  tags = {
    environment = var.environment
    project     = var.project
    owner       = var.owner
  }
}

# ==============================================================================
# Random string — unicité DNS des noms globalement uniques
# ==============================================================================
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  lower   = true
  numeric = true
  special = false
}

# ==============================================================================
# Resource group
# ==============================================================================
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.base_name}"
  location = var.resource_group_location

  tags = local.tags
}

# ==============================================================================
# Virtual network and subnets
# ==============================================================================
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.base_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = local.tags
}

resource "azurerm_subnet" "platform" {
  name                 = "snet-platform-${local.base_name}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "asp" {
  name                 = "snet-asp-${local.base_name}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  # Required for Web App regional VNET integration
  delegation {
    name = "delegation-appservice"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}

# ==============================================================================
# Azure Managed Redis (Balanced B0)
# ==============================================================================
# `azurerm_redis_cache` (Azure Cache for Redis classique) refuse désormais
# toute nouvelle création : le service est en cours de retrait au profit
# d'Azure Managed Redis (architecture Redis Enterprise), constaté au premier
# `apply` réel — https://aka.ms/AzureCacheForRedisRetirement. Palier le plus
# bas de la gamme Balanced, ~13$/mois, comparable au Basic C0 remplacé.
#
# Pas de `prevent_destroy` ici : le Redis est une file de messages transitoire,
# pas un stockage. Le protéger ferait échouer le `terraform destroy` complet —
# un RG ne se détruit pas sans son contenu — alors que le teardown entre deux
# sessions est le principal levier de coût. cf. SKILL.md, section lifecycle.
resource "azurerm_managed_redis" "redis" {
  name                = "redis-${local.base_name}-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  sku_name = "Balanced_B0"

  # Le provider laisse l'accès public ouvert par défaut : sans cette ligne, le
  # cache reste joignable depuis Internet sur 10000 avec la seule clé d'accès,
  # et le private endpoint ci-dessous ne sert à rien. Le seul consommateur est
  # la Web App, qui l'atteint par l'intégration VNET.
  public_network_access = "Disabled"

  # Bloc obligatoire à la création, même vide : la base par défaut du cache.
  # `geo_replication_group_name` ne s'applique qu'à partir de Balanced_B3,
  # sans objet ici.
  default_database {}

  tags = local.tags
}

# ==============================================================================
# Private endpoint for Redis
# ==============================================================================
resource "azurerm_private_endpoint" "redis_pe" {
  name                = "pe-redis-${local.base_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.platform.id

  private_service_connection {
    name                           = "redis-privatelink"
    private_connection_resource_id = azurerm_managed_redis.redis.id
    # "redisEnterprise", pas "redisCache" : Azure Managed Redis reste exposé
    # sous le type ARM `Microsoft.Cache/redisEnterprise`, même si la ressource
    # Terraform s'appelle `azurerm_managed_redis`.
    subresource_names    = ["redisEnterprise"]
    is_manual_connection = false
  }

  # C'est Azure qui crée et maintient l'enregistrement A dans la zone, pas
  # Terraform. Écrit à la main, cet enregistrement doit répéter le seul label
  # d'hôte alors que le provider n'expose que le FQDN — c'était précisément le
  # bug corrigé ici. Déléguer supprime la classe d'erreur, et l'enregistrement
  # suit l'IP du private endpoint si elle change.
  private_dns_zone_group {
    name                 = "pdnszg-redis-${local.base_name}"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis_dns.id]
  }

  tags = local.tags
}

# Nom imposé par Azure : la zone privatelink d'un service Redis doit porter
# exactement ce nom, sinon la résolution privée ne fonctionne pas. Hors pattern
# de nommage projet, volontairement. `privatelink.redis.azure.net` pour Azure
# Managed Redis — différent de `privatelink.redis.cache.windows.net` utilisé
# par l'ancien Azure Cache for Redis (classique).
resource "azurerm_private_dns_zone" "redis_dns" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.rg.name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis_dns_link" {
  name                  = "pdnsl-redis-${local.base_name}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.redis_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id

  tags = local.tags
}

# ==============================================================================
# PostgreSQL flexible server
# ==============================================================================
# Le worker écrit les votes ici. Le serveur est en accès privé (VNET
# integration), pas en accès public filtré : il n'a aucun consommateur hors du
# VNET, et un serveur exposé avec sa seule règle de pare-feu reste à portée de
# toute IP autorisée par erreur.
#
# L'accès privé impose un sous-réseau dédié et délégué — un serveur flexible ne
# partage pas son subnet — et sa propre zone DNS privée, distincte du modèle
# private endpoint utilisé pour le Redis.
resource "azurerm_subnet" "psql" {
  name                 = "snet-psql-${local.base_name}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "delegation-postgresql"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# Contrairement à la zone privatelink du Redis, dont le nom est imposé par
# Azure, celle d'un serveur flexible est libre — seul le suffixe
# `.postgres.database.azure.com` l'est.
resource "azurerm_private_dns_zone" "psql_dns" {
  name                = "${local.base_name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "psql_dns_link" {
  name                  = "pdnsl-psql-${local.base_name}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.psql_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id

  tags = local.tags
}

# Généré plutôt que saisi : un mot de passe en variable finit dans
# `terraform.tfvars`, donc dans Git. Il reste en clair dans le state, comme la
# clé Redis — même dette, déjà tracée dans SUIVI.md, même cible (Key Vault +
# identité managée). Ce que ça supprime, c'est le passage par le dépôt.
resource "random_password" "psql_admin" {
  length      = 32
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  special     = true

  # Azure refuse `'`, `"`, `@` et `/` dans le mot de passe administrateur.
  override_special = "!#$%&*()-_=+[]{}"
}

resource "azurerm_postgresql_flexible_server" "psql" {
  name                = "psql-${local.base_name}-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  version    = "16"
  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768

  administrator_login    = var.postgresql_administrator_login
  administrator_password = random_password.psql_admin.result

  # `public_network_access_enabled` ne vaut pas `false` par défaut : laissé
  # absent, l'API le résout à une valeur qui entre en conflit avec
  # `delegated_subnet_id`/`private_dns_zone_id` ci-dessous
  # (ConflictingPublicNetworkAccessAndVirtualNetworkConfiguration au premier
  # `apply` réel) — explicite, pas déduit par le provider.
  public_network_access_enabled = false

  delegated_subnet_id = azurerm_subnet.psql.id
  private_dns_zone_id = azurerm_private_dns_zone.psql_dns.id

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # Sans cette dépendance explicite, Terraform peut créer le serveur avant que
  # la zone ne soit liée au VNET : le serveur est alors joignable par IP mais
  # son nom ne résout pas, et l'erreur ne se voit qu'au premier démarrage du
  # worker.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.psql_dns_link]

  # Pas de `prevent_destroy`, à l'inverse de ce que SKILL.md prévoit pour ce
  # type : la règle vise les données irremplaçables, et ces votes sont des
  # données de démonstration régénérables en une minute. Le poser bloquerait le
  # `terraform destroy` de teardown — un `prevent_destroy` contamine tout le
  # resource group — qui est le principal levier de coût du projet. La fiche est
  # mise à jour dans le même commit.
  lifecycle {
    # `zone` n'est jamais posé ici, mais un bug connu du provider (issue
    # hashicorp/terraform-provider-azurerm#25538, toujours ouverte) le fait
    # parfois recalculer une valeur différente de celle qu'Azure a réellement
    # assignée, dès qu'un autre changement force un `plan` sur ce serveur.
    # Azure refuse ce changement sans `high_availability.standby_availability_zone`
    # à échanger — qu'on n'a pas, ce projet n'a pas de haute dispo. Constaté
    # sur un `apply` réel : `azurerm_subnet.psql` modifié dans le même run a
    # suffi à déclencher un diff sur `zone` qui a fait échouer tout l'apply.
    # Dette tracée dans SUIVI.md — condition de retrait : correctif amont, ou
    # réexamen si la haute dispo est introduite un jour.
    ignore_changes = [zone]
  }

  tags = local.tags
}

# Base applicative dédiée plutôt que la base de maintenance `postgres` utilisée
# en local par `compose.yaml`. Le worker y crée sa table `votes` au démarrage.
resource "azurerm_postgresql_flexible_server_database" "votes" {
  name      = "votes"
  server_id = azurerm_postgresql_flexible_server.psql.id
  collation = "en_US.utf8"
  charset   = "utf8"

  # Le provider détruit la base au `destroy` ; sans ça il refuse, la protection
  # par défaut visant les bases de production.
  lifecycle {
    prevent_destroy = false
  }
}

# ==============================================================================
# Container registry
# ==============================================================================
# Le pipeline Azure DevOps y pousse l'image du worker ; les App Services l'en
# tirent. Nom sans tiret et globalement unique, contraintes propres au type
# (cf. SKILL.md, section nommage) : le pattern projet est concaténé sans
# séparateurs plutôt que tronqué.
resource "azurerm_container_registry" "acr" {
  name                = "acr${replace(local.base_name, "-", "")}${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Basic"

  # L'utilisateur admin distribue un couple identifiant/mot de passe partagé,
  # qu'il faudrait ensuite stocker quelque part — dans les app_settings, donc
  # dans le state. Les App Services tirent leurs images par identité managée
  # (voir plus bas), l'agent de pipeline par sa connexion de service.
  admin_enabled = false

  # Seule ressource du projet volontairement joignable depuis Internet en plus
  # du front de vote. Deux raisons cumulées : le SKU Basic ne supporte pas les
  # private endpoints — il faudrait passer en Premium, environ quatre fois le
  # prix du reste de l'infra réunie — et l'agent Microsoft-hosted du pipeline
  # est hors du VNET, donc incapable de pousser sur un registre fermé.
  # `admin_enabled = false` fait qu'un accès réseau ne suffit pas : il faut un
  # jeton Entra ID et un rôle sur le registre.
  public_network_access_enabled = true

  tags = local.tags
}

# ==============================================================================
# App Service plan
# ==============================================================================
resource "azurerm_service_plan" "voting_app" {
  name                = "asp-${local.base_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = var.service_plan_sku

  tags = local.tags
}

# ==============================================================================
# Web app — vote
# ==============================================================================
resource "azurerm_linux_web_app" "vote" {
  name                = "app-vote-${local.base_name}-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.voting_app.id

  # Remplace la ressource `azurerm_app_service_virtual_network_swift_connection`
  # utilisée jusqu'ici. Les deux font la même chose et le provider interdit de
  # les mélanger sur une même app ; l'argument porté par la ressource évite une
  # ressource séparée par application.
  virtual_network_subnet_id = azurerm_subnet.asp.id

  site_config {
    # L'intégration VNET régionale route déjà les destinations RFC1918 par
    # défaut, mais pas les requêtes DNS de l'app. Sans ce réglage,
    # `redis-....redis.azure.net` se résoudrait hors du VNET, donc vers
    # l'IP publique du cache — désormais fermée — au lieu de la zone
    # privatelink. Le vote casserait au runtime avec un `plan` propre.
    # `route_all` étend le routage à 0.0.0.0/0 et fait passer le DNS par le VNET.
    vnet_route_all_enabled = true

    application_stack {
      docker_registry_url = var.vote_registry_url
      docker_image_name   = var.web_app_vote_docker_image_name
    }
  }

  app_settings = {
    # Format URL, attendu par la bibliothèque `redis` de Python. Le worker, en
    # .NET, en attend un autre — voir plus bas.
    #
    # `urlencode` n'est pas cosmétique : une clé d'accès Azure fait 44
    # caractères base64, donc contient un `/` environ une fois sur deux. Non
    # encodée, elle termine le `netloc` de l'URL au premier `/`, et
    # `redis.from_url()` se connecte à un hôte tronqué. Le tirage se fait à
    # chaque création du cache — l'infra marcherait ou non selon le run.
    #
    # Le port est lu sur `default_database[0].port` plutôt que figé en dur :
    # Azure Managed Redis (architecture Redis Enterprise) n'utilise pas le
    # port 6380 de l'ancien Azure Cache for Redis, mais laisser le provider
    # exposer la valeur réelle évite de la re-deviner si Azure la fait évoluer.
    "REDIS_CONNECTION_STRING"             = "rediss://:${urlencode(azurerm_managed_redis.redis.default_database[0].primary_access_key)}@${azurerm_managed_redis.redis.hostname}:${azurerm_managed_redis.redis.default_database[0].port}/0"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
  }

  tags = local.tags
}

# ==============================================================================
# Web app — worker
# ==============================================================================
# Réglages du worker, isolés dans un local pour rester lisibles à côté du reste
# de la ressource — l'app en est aujourd'hui le seul consommateur.
locals {
  worker_app_settings = {
    # Le worker n'écoute pas 80. Sans ce réglage App Service sonde 80, ne
    # reçoit rien et renvoie 502 sur une application par ailleurs saine.
    "WEBSITES_PORT" = "8080"

    # Format de chaîne de StackExchange.Redis, différent de l'URL `rediss://`
    # donnée au front de vote : la bibliothèque .NET ne sait pas lire ce schéma.
    # Pas d'encodage nécessaire ici, à l'inverse de l'URL du vote : ce format
    # n'est pas une URL, la clé y est une valeur de champ.
    # `abortConnect=False` laisse le multiplexeur retenter au lieu d'échouer
    # définitivement si le cache n'est pas encore prêt au démarrage. Port lu
    # sur `default_database[0].port`, comme pour le vote — voir plus haut.
    "REDIS_CONNECTION_STRING" = "${azurerm_managed_redis.redis.hostname}:${azurerm_managed_redis.redis.default_database[0].port},password=${azurerm_managed_redis.redis.default_database[0].primary_access_key},ssl=True,abortConnect=False"

    "POSTGRESQL_CONNECTION_STRING" = join(";", [
      "Host=${azurerm_postgresql_flexible_server.psql.fqdn}",
      "Port=5432",
      "Database=${azurerm_postgresql_flexible_server_database.votes.name}",
      "Username=${var.postgresql_administrator_login}",
      "Password=${random_password.psql_admin.result}",
      "SSL Mode=Require",
      "Trust Server Certificate=true",
    ])

    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
  }
}

# Le worker n'est pas une application web : c'est un consommateur de file qui
# tourne en continu. App Service exige malgré tout qu'un conteneur Linux réponde
# sur un port, sinon il le recycle en boucle — d'où le serveur `/healthz` du
# worker, exposé sur 8080.
resource "azurerm_linux_web_app" "worker" {
  name                = "app-worker-${local.base_name}-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.voting_app.id

  virtual_network_subnet_id = azurerm_subnet.asp.id

  # Sert à deux choses : tirer l'image de l'ACR sans identifiants, et porter le
  # rôle `AcrPull` attribué plus bas.
  identity {
    type = "SystemAssigned"
  }

  site_config {
    # Même raison que pour le vote : sans ça, l'app résout les noms du cache et
    # de la base hors du VNET, donc hors des zones DNS privées.
    vnet_route_all_enabled = true

    # Le pull passe par l'identité managée. Sans cette ligne, App Service
    # cherche des identifiants de registre dans les app_settings et échoue —
    # l'ACR a `admin_enabled = false`, il n'y en a aucun.
    container_registry_use_managed_identity = true

    # Slash final volontaire : le worker enregistre le préfixe
    # `http://*:8080/healthz/`. HttpListener sous Windows accepte la requête
    # sans slash, l'implémentation managée utilisée sous Linux — celle du
    # conteneur — ne le garantit pas. Le chemin exact vaut mieux qu'un pari :
    # une sonde qui échoue ici recycle le conteneur en boucle.
    health_check_path = "/healthz/"

    # Le provider exige les deux en même temps dès que l'un est posé, même sur
    # un plan à instance unique où il n'y a rien vers quoi basculer. Valeur
    # minimale acceptée (2-10) : rien à optimiser tant qu'il n'y a pas de
    # deuxième instance.
    health_check_eviction_time_in_min = 2

    application_stack {
      docker_registry_url = "https://${azurerm_container_registry.acr.login_server}"
      docker_image_name   = var.web_app_worker_docker_image_name
    }
  }

  app_settings = local.worker_app_settings

  # Le tag d'image appartient au pipeline, pas à Terraform : chaque run pousse
  # `$(Build.BuildId)` et déploie ce tag. Sans cette ligne, le `terraform apply`
  # suivant ramènerait l'app à la valeur figée dans `terraform.tfvars` et
  # annulerait silencieusement le dernier déploiement. Terraform ne pose donc
  # que la valeur d'amorçage, à la création.
  lifecycle {
    ignore_changes = [site_config[0].application_stack[0].docker_image_name]
  }

  tags = local.tags
}

# ==============================================================================
# ACR pull permissions
# ==============================================================================
# Écrire une attribution de rôle demande un droit que `Contributor` n'a pas.
# La connexion de service du pipeline porte donc `User Access Administrator` en
# plus, sur le seul resource group du projet — sans quoi elle ne pourrait pas
# lancer le `terraform apply` jusqu'au bout. Attribué hors Terraform : le SP ne
# peut pas s'accorder à lui-même le droit dont il a besoin pour le faire.
resource "azurerm_role_assignment" "worker_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.worker.identity[0].principal_id
}
