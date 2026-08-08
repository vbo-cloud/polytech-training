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

resource "azurerm_private_dns_a_record" "redis_record" {
  name                = azurerm_redis_cache.redis.hostname
  zone_name           = azurerm_private_dns_zone.redis_dns.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.redis_pe.private_service_connection[0].private_ip_address]

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
    application_stack {
      docker_registry_url = var.registry_url
      docker_image_name   = var.web_app_vote_docker_image_name
    }
  }

  app_settings = {
    "REDIS_CONNECTION_STRING"             = "rediss://:${azurerm_redis_cache.redis.primary_access_key}@${azurerm_redis_cache.redis.hostname}:6380/0"
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
