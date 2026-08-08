terraform {
  # Le cœur Terraform est pinné au même titre que les providers. `variables.tf`
  # utilise `startswith()` et `endswith()`, apparus en 1.3 ; le plancher est
  # posé plus haut pour laisser la place à la validation croisée entre
  # variables (1.9), attendue dès que les App Services worker/result
  # arriveront. Sans ce pin, un agent CI sur une version plus ancienne échoue
  # de façon cryptique.
  required_version = "~> 1.9"

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
}
