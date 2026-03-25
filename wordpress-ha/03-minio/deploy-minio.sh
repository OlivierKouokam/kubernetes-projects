#!/usr/bin/env bash
# =============================================================
# Phase 3 — Déploiement MinIO HA (MinIO Operator + Tenant)
#
# Prérequis :
#   - Phases 1 & 2 terminées (namespace wordpress-ha existant)
#   - kubectl configuré
#   - helm 3.x installé
#   - StorageClass "example-nfs" disponible
#   - 4 nœuds workers disponibles pour le Tenant (ou tolérances
#     si moins de nœuds — l'anti-affinité est en "preferred")
#
# Usage :
#   chmod +x deploy-minio.sh
#   ./deploy-minio.sh
# =============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

NAMESPACE="wordpress-ha"
OPERATOR_NS="minio-operator"
HELM_REPO_NAME="minio-operator"
HELM_REPO_URL="https://operator.min.io/"
TENANT_NAME="minio-tenant"

kubectl get namespace ${NAMESPACE} &>/dev/null || \
  error "Namespace ${NAMESPACE} introuvable — lancer les phases 1 & 2 d'abord"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 1 — Repo Helm MinIO Operator
# ─────────────────────────────────────────────────────────────
info "Étape 1/7 — Ajout du repo Helm MinIO Operator..."
helm repo add ${HELM_REPO_NAME} ${HELM_REPO_URL} 2>/dev/null || true
helm repo update
helm search repo minio-operator/operator
success "Repo Helm MinIO Operator ajouté"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 2 — Installation de l'opérateur MinIO
# ─────────────────────────────────────────────────────────────
info "Étape 2/7 — Installation du MinIO Operator..."
kubectl create namespace ${OPERATOR_NS} --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install minio-operator ${HELM_REPO_NAME}/operator \
  --namespace ${OPERATOR_NS} \
  --values operator/values-minio-operator.yaml \
  --wait \
  --timeout 5m

success "MinIO Operator installé dans namespace ${OPERATOR_NS}"

info "Attente du démarrage de l'opérateur..."
kubectl rollout status deployment/minio-operator -n ${OPERATOR_NS} --timeout=2m

# Vérification CRDs
info "Vérification des CRDs MinIO..."
kubectl get crd | grep minio.min.io || error "CRDs MinIO non trouvés"
success "CRDs MinIO enregistrés"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 3 — Secrets MinIO
# ─────────────────────────────────────────────────────────────
info "Étape 3/7 — Création des Secrets MinIO..."
warn "Credentials par défaut — modifier avant usage production :"
warn "  Root     : minio / MinIOr00t!2024"
warn "  WP user  : wp-minio-user / WPMinIO!S3c2024"
kubectl apply -f secrets/minio-secrets.yaml
success "Secrets MinIO créés"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 4 — Déploiement du Tenant
# ─────────────────────────────────────────────────────────────
info "Étape 4/7 — Déploiement du Tenant MinIO (mode distribué HA)..."
info "Topologie : 4 serveurs × 2 drives = 8 drives — Erasure Coding EC:4"

kubectl apply -f tenant/minio-tenant-cr.yaml
success "Tenant MinIO créé"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 5 — Attente que le Tenant soit Ready
# ─────────────────────────────────────────────────────────────
info "Étape 5/7 — Attente que le Tenant soit Initialized..."
info "Cela peut prendre 5 à 8 minutes (8 PVCs à provisionner + sync EC)..."

MAX_WAIT=600
ELAPSED=0
INTERVAL=15

while true; do
  # Compter les pods MinIO Running
  READY_PODS=$(kubectl get pods -n ${NAMESPACE} \
    -l v1.min.io/tenant=${TENANT_NAME} \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | wc -l)

  # Vérifier le statut du Tenant CR
  TENANT_HEALTH=$(kubectl get tenant ${TENANT_NAME} -n ${NAMESPACE} \
    -o jsonpath='{.status.healthStatus}' 2>/dev/null || echo "unknown")

  info "Pods MinIO Running : ${READY_PODS}/4 — Health: ${TENANT_HEALTH} (${ELAPSED}s)"

  if [ "${READY_PODS}" -ge 4 ] && [ "${TENANT_HEALTH}" = "green" ]; then
    success "Tenant MinIO Ready — Health: green !"
    break
  fi

  # Fallback : si 4 pods running mais health pas encore vert
  if [ "${READY_PODS}" -ge 4 ] && [ ${ELAPSED} -ge 120 ]; then
    warn "4 pods Running mais health=${TENANT_HEALTH} — on continue quand même"
    break
  fi

  if [ ${ELAPSED} -ge ${MAX_WAIT} ]; then
    warn "Timeout — vérifier : kubectl get tenant ${TENANT_NAME} -n ${NAMESPACE}"
    break
  fi

  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ─────────────────────────────────────────────────────────────
# ÉTAPE 6 — Init bucket + utilisateur WordPress
# ─────────────────────────────────────────────────────────────
info "Étape 6/7 — Initialisation bucket wp-uploads + user WordPress..."
kubectl apply -f buckets/minio-init-configmap.yaml
kubectl apply -f buckets/minio-init-job.yaml

info "Attente du Job d'initialisation MinIO..."
kubectl wait --for=condition=complete job/minio-init \
  -n ${NAMESPACE} \
  --timeout=5m

success "Bucket wp-uploads configuré + user WordPress créé !"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 7 — NodePort de test
# ─────────────────────────────────────────────────────────────
info "Étape 7/7 — Application des services NodePort de test..."
kubectl apply -f tenant/minio-nodeport-test.yaml
success "Services NodePort MinIO créés"

# ─────────────────────────────────────────────────────────────
# RÉCAPITULATIF
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Phase 3 — MinIO HA déployé avec succès !         ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo -e "${BLUE}Tenant MinIO :${NC}"
kubectl get tenant -n ${NAMESPACE}
echo ""

echo -e "${BLUE}Pods MinIO :${NC}"
kubectl get pods -n ${NAMESPACE} -l v1.min.io/tenant=${TENANT_NAME} -o wide
echo ""

echo -e "${BLUE}PVCs MinIO :${NC}"
kubectl get pvc -n ${NAMESPACE} | grep -i minio
echo ""

echo -e "${YELLOW}━━━ Accès Console MinIO ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  URL     : ${GREEN}http://${NODE_IP}:30901${NC}"
echo -e "  Login   : ${GREEN}minio${NC}"
echo -e "  Password: ${GREEN}MinIOr00t!2024${NC}"
echo ""
echo -e "${YELLOW}━━━ Test API S3 avec mc ━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  # Configurer alias"
echo -e "  ${GREEN}mc alias set wplab http://${NODE_IP}:30900 minio MinIOr00t!2024${NC}"
echo ""
echo -e "  # Lister les buckets"
echo -e "  ${GREEN}mc ls wplab/${NC}"
echo ""
echo -e "  # Vérifier le bucket wp-uploads"
echo -e "  ${GREEN}mc ls wplab/wp-uploads/${NC}"
echo ""
echo -e "  # Test upload"
echo -e "  ${GREEN}echo 'test' | mc pipe wplab/wp-uploads/test.txt${NC}"
echo ""
echo -e "  # Vérifier l'utilisateur WordPress"
echo -e "  ${GREEN}mc admin user info wplab wp-minio-user${NC}"
echo ""
echo -e "${YELLOW}━━━ Endpoints internes pour WordPress (Phase 4) ━━━${NC}"
echo ""
echo -e "  API S3    : http://minio-tenant-hl.wordpress-ha.svc.cluster.local:9000"
echo -e "  Bucket    : wp-uploads"
echo -e "  Region    : us-east-1"
echo -e "  Access Key: wp-minio-user   (depuis Secret minio-wp-credentials)"
echo -e "  Secret Key: WPMinIO!S3c2024 (depuis Secret minio-wp-credentials)"
echo ""
echo -e "${YELLOW}━━━ Prochaine étape ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Phase 4 : WordPress HA + configuration Redis + MinIO"
echo ""
