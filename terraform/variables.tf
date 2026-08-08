# ==============================================================================
# Naming and tagging
# ==============================================================================
variable "project" {
  type        = string
  default     = "poly"
  description = "Project token used in every resource name and in the `project` tag."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Environment token used in every resource name and in the `environment` tag. A single environment exists (CLAUDE.md decision #13) — dev/prod are simulated with App Service deployment slots."

  validation {
    condition     = contains(["dev"], var.environment)
    error_message = "Un seul environnement est prévu sur ce projet : dev (décision #13). Ajouter une valeur ici implique d'arbitrer le coût d'une infra dupliquée."
  }
}

variable "owner" {
  type        = string
  default     = "vincent"
  description = "Value of the `owner` tag on every resource."
}

# ==============================================================================
# Infrastructure
# ==============================================================================
variable "resource_group_location" {
  type        = string
  default     = "francecentral"
  description = "Azure region hosting every resource of the project (CLAUDE.md decision #14). The naming token (frc, weu...) is derived from this value by `local.region_short_by_location` in main.tf — there is deliberately no second variable to keep in sync."

  # La liste reste plus large que la décision #14 (`francecentral`), à la
  # différence de `environment` verrouillé sur une seule valeur : ce qu'elle
  # garantit n'est pas le respect de la décision mais l'existence d'un jeton de
  # nommage. Changer de région reste possible sans toucher à la validation,
  # déplacer l'infra dans un second environnement non.
  validation {
    condition     = contains(["francecentral", "westeurope", "northeurope"], var.resource_group_location)
    error_message = "Région non reconnue. Ce champ pilote aussi le jeton de région des noms de ressources : ajouter une région ici impose d'ajouter son jeton court dans `local.region_short_by_location` (main.tf), sinon le plan échoue sur un index manquant."
  }
}

# ==============================================================================
# Container image
# ==============================================================================
variable "registry_url" {
  type        = string
  default     = ""
  description = "Registry URL."
}

variable "web_app_vote_docker_image_name" {
  type        = string
  default     = ""
  description = "Docker image of vote."
}
