# ==============================================================================
# Valeurs consommées par le pipeline
# ==============================================================================
# Destinées à être lues par le stage `Infra` d'un futur pipeline CI (branche à
# venir), qui les republierait en variables de pipeline pour les stages
# `Publish` et `Deploy`. Elles ne sont **pas** recopiées dans un groupe de
# variables : les noms d'App Service et d'ACR portent le suffixe aléatoire de
# `random_string`, tiré à chaque création, donc renouvelé à chaque cycle
# destroy / apply — et le teardown entre deux sessions est la routine du
# projet. Une valeur figée à la main serait périmée au premier teardown.
#
# Aucune n'est sensible : ce sont des noms de ressources. Les identifiants
# n'apparaissent nulle part ici, l'authentification du pipeline passant par la
# connexion de service ARM et l'identité managée de l'App Service.

output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Resource group holding every resource of the project. Feeds the `resourceGroupName` pipeline variable."
}

output "acr_name" {
  value       = azurerm_container_registry.acr.name
  description = "Container registry name, as expected by `az acr build --registry`. Feeds the `acrName` pipeline variable."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "Container registry host, used to build the full image reference at deploy time. Feeds the `acrLoginServer` pipeline variable. No https:// prefix, unlike the value App Service expects in `docker_registry_url`."
}

output "worker_web_app_name" {
  value       = azurerm_linux_web_app.worker.name
  description = "Worker web app name. Feeds the `workerWebAppName` pipeline variable, which the deploy stage targets directly — the plan is Basic, so there is no slot to deploy through (CLAUDE.md decision #11)."
}

# ==============================================================================
# Points d'entrée applicatifs
# ==============================================================================
output "vote_url" {
  value       = "https://${azurerm_linux_web_app.vote.default_hostname}"
  description = "Public URL of the vote front end — the only application endpoint reachable from outside the VNET."
}

output "postgresql_fqdn" {
  value       = azurerm_postgresql_flexible_server.psql.fqdn
  description = "Private FQDN of the PostgreSQL flexible server. Resolves only from inside the VNET: useful to read a plan or debug the worker, not to connect from a workstation."
}
