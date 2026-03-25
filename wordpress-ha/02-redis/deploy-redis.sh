#!/usr/bin/env bash
# =============================================================
# Phase 2 — Déploiement Redis HA (Sentinel via OT-SCNG Operator)
#
# Prérequis :
#   - Phase 1 MySQL terminée (namespace wordpress-ha existant)
#   - kubectl configuré
#   - helm 3.x installé
#   - StorageClass "example-nfs" disponible
#
# Usage :
#   chmod +x deploy-redis.sh
#   ./deploy-redis.sh
# =============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

NAMESPACE="wordpress-ha"
OPERATOR_NS="redis-operator"
HELM_REPO_NAME="ot-helm"
HELM_REPO_URL="https://ot-container-kit.github.io/helm-charts/"

# Vérification namespace Phase 1
kubectl get namespace ${NAMESPACE} &>/dev/null || \
  error "Namespace ${NAMESPACE} introuvable — lancer la Phase 1 d'abord"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 1 — Repo Helm OT-SCNG
# ─────────────────────────────────────────────────────────────
info "Étape 1/6 — Ajout du repo Helm OT-SCNG..."
helm repo add ${HELM_REPO_NAME} ${HELM_REPO_URL} 2>/dev/null || true
helm repo update
helm search repo ot-helm/redis-operator
success "Repo Helm OT-SCNG ajouté"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 2 — Installation de l'opérateur Redis
# ─────────────────────────────────────────────────────────────
info "Étape 2/6 — Installation du Redis Operator (OT-SCNG)..."

kubectl create namespace ${OPERATOR_NS} --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install redis-operator ${HELM_REPO_NAME}/redis-operator \
  --namespace ${OPERATOR_NS} \
  --values operator/values-redis-operator.yaml \
  --wait \
  --timeout 5m

success "Redis Operator installé dans namespace ${OPERATOR_NS}"

info "Attente du démarrage de l'opérateur..."
kubectl rollout status deployment/redis-operator -n ${OPERATOR_NS} --timeout=2m

# Vérification que les CRDs sont bien enregistrés
info "Vérification des CRDs Redis..."
kubectl get crd | grep redis.opstreelabs.in || \
  error "CRDs Redis non trouvés — l'opérateur n'a pas démarré correctement"
success "CRDs Redis enregistrés"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 3 — Secret Redis
# ─────────────────────────────────────────────────────────────
info "Étape 3/6 — Création du Secret Redis..."
warn "Mot de passe par défaut : RedisSent!n3l2024 — modifier si besoin"
kubectl apply -f secrets/redis-secret.yaml
success "Secret redis-credentials créé"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 4 — ConfigMap Redis (tuning)
# ─────────────────────────────────────────────────────────────
info "Étape 4/6 — Application du ConfigMap Redis..."
kubectl apply -f cluster/redis-config.yaml
success "ConfigMap redis-config créé"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 5 — Déploiement RedisSentinel
# ─────────────────────────────────────────────────────────────
info "Étape 5/6 — Déploiement du cluster RedisSentinel..."
kubectl apply -f cluster/redis-sentinel-cr.yaml

info "Attente du démarrage des pods Redis (master + replicas + sentinels)..."
info "Cela prend généralement 2 à 4 minutes..."

# Attente des pods Redis (3 pods redis + 3 pods sentinel = 6 au total)
MAX_WAIT=360
ELAPSED=0
INTERVAL=10

while true; do
  READY_REDIS=$(kubectl get pods -n ${NAMESPACE} \
    -l app=redis-sentinel \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | wc -l)

  info "Pods Redis Running : ${READY_REDIS}/6 (${ELAPSED}s)"

  if [ "${READY_REDIS}" -ge 6 ]; then
    success "Tous les pods Redis sont Running !"
    break
  fi

  if [ ${ELAPSED} -ge ${MAX_WAIT} ]; then
    warn "Timeout — vérifier manuellement : kubectl get pods -n ${NAMESPACE}"
    break
  fi

  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ─────────────────────────────────────────────────────────────
# ÉTAPE 6 — NodePort de test
# ─────────────────────────────────────────────────────────────
info "Étape 6/6 — Application des services NodePort de test..."
kubectl apply -f cluster/redis-nodeport-test.yaml
success "Services NodePort Redis créés"

# ─────────────────────────────────────────────────────────────
# RÉCAPITULATIF
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Phase 2 — Redis HA Sentinel déployé !            ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo -e "${BLUE}Pods Redis :${NC}"
kubectl get pods -n ${NAMESPACE} -l app=redis-sentinel -o wide
echo ""

echo -e "${BLUE}Services :${NC}"
kubectl get svc -n ${NAMESPACE} | grep -i redis
echo ""

echo -e "${YELLOW}━━━ Tests de connexion ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Ping Redis master :"
echo -e "  ${GREEN}redis-cli -h ${NODE_IP} -p 30379 -a 'RedisSent!n3l2024' ping${NC}"
echo ""
echo -e "  Info réplication :"
echo -e "  ${GREEN}redis-cli -h ${NODE_IP} -p 30379 -a 'RedisSent!n3l2024' INFO replication${NC}"
echo ""
echo -e "  Interroger Sentinel (master actuel) :"
echo -e "  ${GREEN}redis-cli -h ${NODE_IP} -p 30380 SENTINEL get-master-addr-by-name mymaster${NC}"
echo ""
echo -e "${YELLOW}━━━ Endpoints internes pour WordPress (Phase 4) ━━━${NC}"
echo ""
echo -e "  Sentinel  : redis-sentinel-service:26379"
echo -e "  Master    : redis-sentinel-master-service:6379"
echo -e "  Nom logique master : mymaster"
echo ""
echo -e "${YELLOW}━━━ Prochaine étape ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Phase 3 : MinIO Operator (stockage médias WordPress)"
echo ""
