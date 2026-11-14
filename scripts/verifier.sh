#!/usr/bin/env bash
# =====================================================================================
# Contrôle post-déploiement (smoke tests) : l'application répond-elle vraiment ?
#   ./scripts/verifier.sh
# Les tests passent par le conteneur frontend : on teste le même chemin qu'un utilisateur
# (nginx -> gateway -> Eureka -> microservices).
# =====================================================================================
set -uo pipefail

PROJET=jangalma
RAPPORT="deploy-report.txt"
ECHECS=0
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RAPPORT"; }
ok()  { log "  OK    $*"; }
ko()  { log "  ECHEC $*"; ECHECS=$((ECHECS + 1)); }

FRONT=$(docker ps -q --filter "label=com.docker.compose.project=$PROJET" \
                     --filter "label=com.docker.compose.service=frontend" | head -1)
[ -n "$FRONT" ] || { log "ECHEC : conteneur frontend introuvable"; exit 1; }

# Code HTTP d'une URL vue depuis le frontend (wget de busybox affiche l'en-tête avec -S)
code_http() {
  docker exec "$FRONT" sh -c "wget -S -q -O /dev/null '$1' 2>&1" \
    | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | tail -1 | awk '{print $2+0}'
}
attendu() { # attendu <description> <url> <code attendu>
  local code; code=$(code_http "$2")
  [ "$code" = "$3" ] && ok "$1 ($code)" || ko "$1 : reçu $code, attendu $3"
}

log "=== Contrôle post-déploiement ==="

log "1) État des conteneurs"
for nom in $(docker ps --filter "label=com.docker.compose.project=$PROJET" --format '{{.Names}}' | sort); do
  etat=$(docker inspect -f '{{.State.Health.Status}}' "$nom")
  [ "$etat" = "healthy" ] && ok "$nom" || ko "$nom : $etat"
done

log "2) Services enregistrés dans Eureka"
for app in API-GATEWAY IDENTITY-SERVICE ACADEMIC-SERVICE MATCHING-SERVICE RESOURCE-SERVICE NOTIFICATION-SERVICE; do
  attendu "Eureka : $app" "http://eureka-server:8761/eureka/apps/$app" 200
done

log "3) Parcours utilisateur (via nginx)"
attendu "Frontend /health"                    "http://127.0.0.1:8080/health" 200
attendu "Page d'accueil Angular"              "http://127.0.0.1:8080/" 200
attendu "Gateway /actuator/health"            "http://api-gateway:8080/actuator/health" 200
attendu "API protégée sans jeton (=> 401)"    "http://127.0.0.1:8080/api/v1/utilisateurs/me" 401

if [ "$ECHECS" -eq 0 ]; then
  log "=== Contrôle réussi : application opérationnelle ==="
else
  log "=== Contrôle échoué : $ECHECS problème(s) ==="
  exit 1
fi
