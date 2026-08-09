resource_group_location = "francecentral"

# Le vote reste sur le registre public d'Avisto : le pipeline ne construit que
# l'image du worker. Le worker, lui, ne figure pas ici — son registre est l'ACR
# du projet, dont l'URL n'est connue qu'à l'apply.
vote_registry_url              = "https://rgy.k8s.devops-svc-ag.com"
web_app_vote_docker_image_name = "polytech/vote:1.0.1"

# Valeur d'amorçage uniquement : le pipeline reprend la main sur le tag dès son
# premier run (cf. `ignore_changes` dans main.tf).
web_app_worker_docker_image_name = "polytech/worker:0.1.0"
