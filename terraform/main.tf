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
# Redis cache (Basic)
# ==============================================================================
# Pas de `prevent_destroy` ici : le Redis est une file de messages transitoire,
# pas un stockage. Le protéger ferait échouer le `terraform destroy` complet —
# un RG ne se détruit pas sans son contenu — alors que le teardown entre deux
# sessions est le principal levier de coût. cf. SKILL.md, section lifecycle.
resource "azurerm_redis_cache" "redis" {
  name                = "redis-${local.base_name}-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  capacity = 0
  family   = "C"
  sku_name = "Basic"

  minimum_tls_version = "1.2"

  # Le provider laisse l'accès public à `true` par défaut : sans cette ligne, le
  # cache reste joignable depuis Internet sur 6380 avec la seule clé d'accès, et
  # le private endpoint ci-dessous ne sert à rien. Le seul consommateur est la
  # Web App, qui l'atteint par l'intégration VNET.
  public_network_access_enabled = false

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
    private_connection_resource_id = azurerm_redis_cache.redis.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
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
# de nommage projet, volontairement.
resource "azurerm_private_dns_zone" "redis_dns" {
  name                = "privatelink.redis.cache.windows.net"
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
  sku_name            = "B1"

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

  site_config {
    # L'intégration VNET régionale route déjà les destinations RFC1918 par
    # défaut, mais pas les requêtes DNS de l'app. Sans ce réglage,
    # `redis-....redis.cache.windows.net` se résoudrait hors du VNET, donc vers
    # l'IP publique du cache — désormais fermée — au lieu de la zone
    # privatelink. Le vote casserait au runtime avec un `plan` propre.
    # `route_all` étend le routage à 0.0.0.0/0 et fait passer le DNS par le VNET.
    vnet_route_all_enabled = true

    application_stack {
      docker_registry_url = var.registry_url
      docker_image_name   = var.web_app_vote_docker_image_name
    }
  }

  app_settings = {
    # `urlencode` n'est pas cosmétique : une clé d'accès Azure fait 44
    # caractères base64, donc contient un `/` environ une fois sur deux. Non
    # encodée, elle termine le `netloc` de l'URL au premier `/`, et
    # `redis.from_url()` se connecte à un hôte tronqué. Le tirage se fait à
    # chaque création du cache — l'infra marcherait ou non selon le run.
    "REDIS_CONNECTION_STRING"             = "rediss://:${urlencode(azurerm_redis_cache.redis.primary_access_key)}@${azurerm_redis_cache.redis.hostname}:6380/0"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
  }

  tags = local.tags
}

# ==============================================================================
# Web app VNET integration
# ==============================================================================
resource "azurerm_app_service_virtual_network_swift_connection" "vnet_integration" {
  app_service_id = azurerm_linux_web_app.vote.id
  subnet_id      = azurerm_subnet.asp.id
}
