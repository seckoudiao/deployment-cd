#!/usr/bin/env bash
# =====================================================================================
# Déploiement continu de Jangalma, sans coupure (rolling update), lancé par Jenkins.
#
#   SECRETS_ENV=/chemin/secrets.env ./scripts/deploy.sh
#   FORCER="identity-service api-gateway" ...   => redéploie ces services même sans changement (démo)
#
# Principe pour chaque service dont l'image a changé sur Docker Hub :
#   1. on démarre une 2e instance avec la nouvelle image (l'ancienne continue de servir) ;
#   2. on attend que la nouvelle soit « healthy » (sinon : on la supprime, l'ancienne reste => rollback) ;
#   3. on retire l'ancienne d'Eureka (OUT_OF_SERVICE) et on laisse le trafic basculer (DRAIN_S) ;
#   4. on arrête proprement l'ancienne.
# Les services inchangés ne sont pas touchés. MySQL et MinIO ne sont jamais recréés (données).
# =====================================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SECRETS_ENV:?SECRETS_ENV doit pointer vers le fichier secrets.env}"
COMPOSE=(docker compose --env-file .env --env-file "$SECRETS_ENV")
PROJET=jangalma
RESEAU="${PROJET}_default"
EUREKA_URL="http://eureka-server:8761/eureka"
CURL_IMAGE="curlimages/curl:8.11.1"
HEALTH_TIMEOUT_S="${HEALTH_TIMEOUT_S:-300}"   # temps max pour qu'une instance devienne healthy
DRAIN_S="${DRAIN_S:-20}"                       # bascule du trafic (cache Eureka 3 s + fetch 5 s + LB 5 s + marge)

# Port interne de chaque microservice (sert à construire l'identifiant d'instance Eureka)
declare -A PORT=(
  [api-gateway]=8080 [identity-service]=8081 [academic-service]=8082
  [matching-service]=8083 [resource-service]=8084 [notification-service]=8085
)
# Ordre de mise à jour : le registre d'abord, la gateway et le frontend en dernier
SERVICES_ROULANTS=(identity-service academic-service matching-service resource-service notification-service api-gateway)

RAPPORT="deploy-report.txt"
: > "$RAPPORT"
log()     { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RAPPORT"; }
echouer() { log "ECHEC : $*"; exit 1; }

# Conteneurs (en cours d'exécution) d'un service du projet
conteneurs() {
  docker ps -q --filter "label=com.docker.compose.project=$PROJET" \
               --filter "label=com.docker.compose.service=$1"
}

# Vrai si le conteneur doit être remplacé : nouvelle image tirée OU configuration modifiée
# dans docker-compose.yml / .env (Compose étiquette chaque conteneur avec un hash de sa config).
a_mettre_a_jour() {
  local cid=$1 service=$2 ref actuelle nouvelle hash_actuel hash_attendu
  if [[ " ${FORCER:-} " == *" $service "* ]]; then
    log "$service : redéploiement forcé (FORCER)"
    return 0
  fi
  ref=$(docker inspect -f '{{.Config.Image}}' "$cid")
  actuelle=$(docker inspect -f '{{.Image}}' "$cid")
  nouvelle=$(docker image inspect -f '{{.Id}}' "$ref")
  if [ "$actuelle" != "$nouvelle" ]; then
    log "$service : nouvelle image"
    return 0
  fi
  hash_actuel=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$cid")
  hash_attendu=$("${COMPOSE[@]}" config --hash "$service" | awk '{print $2}')
  if [ "$hash_actuel" != "$hash_attendu" ]; then
    log "$service : configuration modifiée"
    return 0
  fi
  return 1
}

attendre_healthy() {
  local cid=$1 etat fin=$((SECONDS + HEALTH_TIMEOUT_S))
  while [ $SECONDS -lt $fin ]; do
    etat=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo absent)
    case "$etat" in
      healthy)   return 0 ;;
      unhealthy) return 1 ;;
    esac
    sleep 5
  done
  return 1
}

# Retire une instance d'Eureka : la gateway cesse de lui envoyer des requêtes
eureka_hors_service() {
  local service=$1 cid=$2 app instance
  app=$(echo "$service" | tr '[:lower:]' '[:upper:]')
  instance="${cid:0:12}:${service}:${PORT[$service]}"   # hostname du conteneur:nom:port
  docker run --rm --network "$RESEAU" "$CURL_IMAGE" -fsS -o /dev/null -X PUT \
    "$EUREKA_URL/apps/$app/$instance/status?value=OUT_OF_SERVICE" \
    && log "  $instance retiré d'Eureka" \
    || log "  (avertissement) retrait Eureka impossible pour $instance, arrêt direct"
}

mise_a_jour_roulante() {
  local service=$1 ancien nouveau
  ancien=$(conteneurs "$service" | head -1)

  if [ -z "$ancien" ]; then
    log "$service : absent, création"
    "${COMPOSE[@]}" up -d --no-deps "$service"
    attendre_healthy "$(conteneurs "$service" | head -1)" || echouer "$service ne démarre pas"
    return
  fi
  if ! a_mettre_a_jour "$ancien" "$service"; then
    log "$service : à jour, rien à faire"
    return
  fi

  log "$service : démarrage d'une 2e instance"
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "$service=2" "$service"
  nouveau=$(conteneurs "$service" | grep -v "^${ancien:0:12}" | head -1)
  [ -n "$nouveau" ] || echouer "$service : la nouvelle instance n'a pas été créée"

  if ! attendre_healthy "$nouveau"; then
    log "$service : nouvelle instance non healthy => ROLLBACK (l'ancienne continue de servir)"
    docker logs --tail 40 "$nouveau" >> "$RAPPORT" 2>&1 || true
    docker rm -f "$nouveau" >/dev/null
    echouer "$service : déploiement annulé"
  fi
  log "$service : nouvelle instance healthy"

  [ "$service" != "api-gateway" ] && eureka_hors_service "$service" "$ancien"
  log "  bascule du trafic ($DRAIN_S s)"
  sleep "$DRAIN_S"

  docker stop -t 30 "$ancien" >/dev/null   # SIGTERM : arrêt propre, requêtes en cours terminées
  docker rm "$ancien" >/dev/null
  log "$service : ancienne instance arrêtée, mise à jour terminée"
}

# Services remplacés directement (instance unique) : registre Eureka et frontend (port 8088 publié)
remplacement_direct() {
  local service=$1 cid
  cid=$(conteneurs "$service" | head -1)
  if [ -n "$cid" ] && ! a_mettre_a_jour "$cid" "$service"; then
    log "$service : à jour, rien à faire"
    return
  fi
  log "$service : remplacement (instance unique)"
  "${COMPOSE[@]}" up -d --no-deps "$service"
  attendre_healthy "$(conteneurs "$service" | head -1)" || echouer "$service n'est pas healthy"
  if [ "$service" = "eureka-server" ]; then
    attendre_inscriptions
  fi
  log "$service : à jour"
}

# Après un remplacement d'Eureka, le registre est vide : on attend que les services s'y réinscrivent
# avant de continuer (limite connue : Eureka est une instance unique, quelques secondes de trou possibles).
attendre_inscriptions() {
  local n fin=$((SECONDS + 120))
  while [ $SECONDS -lt $fin ]; do
    n=$(docker run --rm --network "$RESEAU" "$CURL_IMAGE" -fsS -H 'Accept: application/json' "$EUREKA_URL/apps" 2>/dev/null \
        | grep -o '"name":"[A-Z-]*"' | sort -u | wc -l)
    [ "$n" -ge 6 ] && { log "  registre Eureka reconstitué ($n services)"; return 0; }
    sleep 3
  done
  log "  (avertissement) registre Eureka incomplet après 120 s"
}

# ----------------------------------------------------------------------------------
log "=== Déploiement Jangalma : $(date '+%d/%m/%Y %H:%M') ==="

log "1) Récupération des images depuis Docker Hub"
"${COMPOSE[@]}" pull --quiet

log "2) Démarrage des services manquants (MySQL, MinIO... jamais recréés)"
"${COMPOSE[@]}" up -d --no-recreate --build mysql minio
attendre_healthy "$(conteneurs mysql | head -1)" || echouer "MySQL n'est pas healthy"
attendre_healthy "$(conteneurs minio | head -1)" || echouer "MinIO n'est pas healthy"

log "3) Mise à jour des services"
remplacement_direct eureka-server
for s in "${SERVICES_ROULANTS[@]}"; do
  mise_a_jour_roulante "$s"
done
remplacement_direct frontend

log "=== Déploiement terminé ==="
