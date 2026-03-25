#!/usr/bin/env bash
# =============================================================
# Phase 4 — Déploiement WordPress HA
#
# Prérequis :
#   - Phase 1 : MySQL InnoDB Cluster ONLINE ✓
#   - Phase 2 : Redis Sentinel opérationnel ✓
#   - Phase 3 : MinIO Tenant health=green ✓
#   - namespace wordpress-ha existant ✓
#
# Ce script déploie :
#   1. Secrets WordPress (DB + Redis + MinIO + Auth Salts)
#   2. ConfigMap wp-config.php
#   3. Deployment WordPress (2 replicas, init containers)
#   4. Service NodePort :30080
#   5. HPA (autoscaling CPU/mémoire)
#   6. PodDisruptionBudget
#   7. Job de post-configuration (activation plugins via WP-CLI)
#
# Usage :
#   chmod +x deploy-wordpress.sh
#   ./deploy-wordpress.sh
# =============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

NAMESPACE="wordpress-ha"

# ── Vérifications pré-déploiement ─────────────────────────────
info "Vérification des prérequis..."

kubectl get namespace ${NAMESPACE} &>/dev/null || \
  error "Namespace ${NAMESPACE} introuvable"

# MySQL
MYSQL_STATUS=$(kubectl get innodbcluster mycluster -n ${NAMESPACE} \
  -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "unknown")
[ "${MYSQL_STATUS}" = "ONLINE" ] || \
  warn "MySQL status=${MYSQL_STATUS} (attendu ONLINE) — continuer quand même ? [Ctrl+C pour annuler]" && sleep 3

# Redis
REDIS_PODS=$(kubectl get pods -n ${NAMESPACE} -l app=redis-sentinel \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
[ "${REDIS_PODS}" -ge 6 ] || \
  warn "Redis : ${REDIS_PODS}/6 pods Running — continuer ? [Ctrl+C pour annuler]" && sleep 3

# MinIO
MINIO_HEALTH=$(kubectl get tenant minio-tenant -n ${NAMESPACE} \
  -o jsonpath='{.status.healthStatus}' 2>/dev/null || echo "unknown")
[ "${MINIO_HEALTH}" = "green" ] || \
  warn "MinIO health=${MINIO_HEALTH} (attendu green) — continuer ? [Ctrl+C pour annuler]" && sleep 3

success "Prérequis vérifiés — démarrage du déploiement WordPress"
echo ""

# ─────────────────────────────────────────────────────────────
# ÉTAPE 1 — Secrets WordPress
# ─────────────────────────────────────────────────────────────
info "Étape 1/7 — Application des Secrets WordPress..."
warn "⚠️  Modifier secrets/wordpress-secrets.yaml AVANT de continuer :"
warn "   - Auth Keys & Salts (générer via https://api.wordpress.org/secret-key/1.1/salt/)"
warn "   - Mot de passe admin WordPress dans le Job post-configure"
echo ""
read -p "  Les secrets sont-ils configurés ? [o/N] " confirm
[[ "${confirm}" =~ ^[oO]$ ]] || error "Modifier les secrets et relancer"

kubectl apply -f secrets/wordpress-secrets.yaml
success "Secrets WordPress créés"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 2 — ConfigMap wp-config.php
# ─────────────────────────────────────────────────────────────
info "Étape 2/7 — Application du ConfigMap wp-config.php..."
kubectl apply -f configmaps/wp-config-configmap.yaml
success "ConfigMap wordpress-config créé"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 3 — Déploiement WordPress
# ─────────────────────────────────────────────────────────────
info "Étape 3/7 — Déploiement WordPress (2 replicas)..."
kubectl apply -f deployment/wordpress-deployment.yaml
kubectl apply -f deployment/wordpress-service.yaml
kubectl apply -f deployment/wordpress-pdb.yaml
success "Deployment + Service + PDB créés"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 4 — Attente que WordPress soit Ready
# ─────────────────────────────────────────────────────────────
info "Étape 4/7 — Attente que WordPress soit Ready..."
info "Les init containers attendent MySQL + Redis + MinIO avant de démarrer..."
info "Ensuite les plugins sont installés — compter 3 à 6 minutes au total..."

kubectl rollout status deployment/wordpress -n ${NAMESPACE} --timeout=15m
success "WordPress Deployment Ready !"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 5 — HPA
# ─────────────────────────────────────────────────────────────
info "Étape 5/7 — Application du HorizontalPodAutoscaler..."

# Vérifier si metrics-server est disponible
if kubectl top pods -n ${NAMESPACE} &>/dev/null 2>&1; then
  kubectl apply -f hpa/wordpress-hpa.yaml
  success "HPA wordpress-hpa créé (min=2, max=10)"
else
  warn "metrics-server non détecté — HPA appliqué mais inactif"
  warn "Pour installer metrics-server :"
  warn "  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  kubectl apply -f hpa/wordpress-hpa.yaml || true
fi

# ─────────────────────────────────────────────────────────────
# ÉTAPE 6 — Job post-configuration (activation plugins)
# ─────────────────────────────────────────────────────────────
info "Étape 6/7 — Lancement du Job de post-configuration..."
info "Ce Job active Redis Object Cache + WP Offload Media via WP-CLI..."

kubectl apply -f plugins/wordpress-postconfigure-job.yaml

info "Attente du Job de post-configuration..."
kubectl wait --for=condition=complete job/wordpress-postconfigure \
  -n ${NAMESPACE} \
  --timeout=10m

success "Post-configuration terminée !"

echo ""
info "Logs du Job :"
kubectl logs -n ${NAMESPACE} job/wordpress-postconfigure --tail=30

# ─────────────────────────────────────────────────────────────
# ÉTAPE 7 — Vérification finale
# ─────────────────────────────────────────────────────────────
info "Étape 7/7 — Vérification finale..."

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test HTTP
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${NODE_IP}:30080/" 2>/dev/null || echo "000")
[ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "302" ] && \
  success "WordPress répond HTTP ${HTTP_CODE}" || \
  warn "WordPress HTTP ${HTTP_CODE} — vérifier les logs"

# ─────────────────────────────────────────────────────────────
# RÉCAPITULATIF FINAL DE LA STACK COMPLÈTE
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Stack WordPress HA — Déploiement complet !          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}── Pods namespace wordpress-ha ──────────────────────────${NC}"
kubectl get pods -n ${NAMESPACE} -o wide
echo ""

echo -e "${BLUE}── Services NodePort ────────────────────────────────────${NC}"
kubectl get svc -n ${NAMESPACE} | grep NodePort
echo ""

echo -e "${BLUE}── HPA ──────────────────────────────────────────────────${NC}"
kubectl get hpa -n ${NAMESPACE}
echo ""

echo -e "${YELLOW}━━━ URLs d'accès ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  WordPress Frontend  : ${GREEN}http://${NODE_IP}:30080${NC}"
echo -e "  WordPress Admin     : ${GREEN}http://${NODE_IP}:30080/wp-admin${NC}"
echo -e "  MySQL NodePort      : ${GREEN}${NODE_IP}:30306${NC}"
echo -e "  Redis NodePort      : ${GREEN}${NODE_IP}:30379${NC} / Sentinel:${GREEN}${NODE_IP}:30380${NC}"
echo -e "  MinIO API S3        : ${GREEN}http://${NODE_IP}:30900${NC}"
echo -e "  MinIO Console       : ${GREEN}http://${NODE_IP}:30901${NC}"
echo ""
echo -e "${YELLOW}━━━ Credentials ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  WP Admin    : admin / WPadmin!2024"
echo -e "  MySQL root  : root  / WPr00tS3cur3!2024"
echo -e "  MinIO root  : minio / MinIOr00t!2024"
echo ""
echo -e "${YELLOW}━━━ Vérifications post-déploiement ━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  1. WordPress frontend accessible"
echo "  2. wp-admin → Réglages > Redis Object Cache → Status: Connected"
echo "  3. wp-admin → Médias > Offload Media → bucket wp-uploads configuré"
echo "  4. Uploader une image → vérifier qu'elle apparaît dans MinIO"
echo "     mc ls wplab/wp-uploads/"
echo ""
echo -e "${YELLOW}━━━ Test de scaling ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  # Scale manuel"
echo "  kubectl scale deployment/wordpress -n ${NAMESPACE} --replicas=4"
echo ""
echo "  # Surveiller le HPA"
echo "  kubectl get hpa wordpress-hpa -n ${NAMESPACE} -w"
echo ""
