terraform {
  # Le cœur Terraform est pinné au même titre que les providers. `variables.tf`
  # utilise `startswith()` et `endswith()`, apparus en 1.3 ; le plancher est
  # posé plus haut pour laisser la place à la validation croisée entre
  # variables (1.9), attendue dès que les App Services worker/result
  # arriveront. Sans ce pin, un agent CI sur une version plus ancienne échoue
  # de façon cryptique.
  required_version = "~> 1.9"

  # State distant, imposé par le passage de l'`apply` dans le pipeline : un
  # agent Azure DevOps est éphémère, un `terraform.tfstate` local disparaît
  # avec lui — et deux runs successifs repartiraient d'un state vide, donc
  # recréeraient tout.
  #
  # Le compte de stockage vit dans `rg-tfstate-poly-dev-frc`, **pas** dans le
  # resource group géré par cette configuration. Un `terraform destroy` de
  # teardown détruit `rg-poly-dev-frc` et tout son contenu : y loger le state
  # reviendrait à le faire s'effacer lui-même en cours de destruction.
  #
  # Ces valeurs sont en dur parce qu'un bloc `backend` n'accepte ni variable ni
  # interpolation. Aucune n'est sensible — l'accès au conteneur passe par
  # Entra ID (`use_azuread_auth`), pas par une clé de compte.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-poly-dev-frc"
    storage_account_name = "sttfstatepolydevfrc"
    container_name       = "tfstate"
    key                  = "poly-dev.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.0"
    }
    # Utilisé par `random_string.suffix` dans main.tf. Sans déclaration
    # explicite, Terraform le résout implicitement et ne le pin pas.
    random = {
      source  = "hashicorp/random"
      version = "~>3.6"
    }
  }
}

provider "azurerm" {
  features {}

  # Par défaut (`"core"`), le provider énumère les resource providers de
  # l'abonnement à sa configuration — une lecture de portée abonnement. Le
  # service principal du pipeline n'a de rôle que sur les resource groups du
  # projet : le stage échouerait avant la première ressource, sur un message
  # parlant d'enregistrement de providers et non de droits manquants.
  #
  # Les élargir à l'abonnement contredirait la règle de SKILL.md — scope au
  # resource group, jamais à toute la souscription. On supprime donc le besoin
  # plutôt que le garde-fou : les providers utilisés ici (Web, Cache,
  # ContainerRegistry, DBforPostgreSQL, Network, Storage) sont déjà enregistrés,
  # et le rester est une opération d'abonnement, pas de projet.
  resource_provider_registrations = "none"
}
