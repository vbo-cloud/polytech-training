resource_group_location = "francecentral"

# Valeurs d'amorçage uniquement : le pipeline reprend la main sur le tag de
# chacune dès son premier run (cf. `ignore_changes` dans main.tf). Les trois
# images sont tirées de l'ACR du projet, pas d'un registre externe.
web_app_vote_docker_image_name   = "polytech/vote:0.1.0"
web_app_worker_docker_image_name = "polytech/worker:0.1.0"
web_app_result_docker_image_name = "polytech/result:0.1.0"
