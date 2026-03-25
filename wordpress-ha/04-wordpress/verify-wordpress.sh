#!/usr/bin/env bash
# =============================================================
# verify-wordpress.sh — Vérification complète de la stack HA
#
# Ce script vérifie l'ensemble de la stack :
#   1. WordPress Deployment + pods
#   2. Connectivité HTTP WordPress
#   3. Redis Object Cache actif
#   4. MinIO / WP Offload Media
#   5. Connexion MySQL
#   6. HPA
#   7. Test de scaling
#   8. Test de résilience (simulation de pannes)
# =============================================================

set -uo pipefail

NAMESPACE="wordpress-ha"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

header() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
info()   { echo -e "  ${BLUE}→${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!${NC} $*"; }

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   Stack WordPress HA — Rapport de vérification    ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Vue d'ensemble de la stack ───────────────────────────────
header "Vue d'ensemble — tous les pods"
kubectl get pods -n ${NAMESPACE} -o wide 2>/dev/null || true
echo ""
kubectl get svc -n ${NAMESPACE} 2>/dev/null || true

# ─── 1. WordPress ─────────────────────────────────────────────
header "1. WordPress Deployment"

DESIRED=$(kubectl get deploy wordpress -n ${NAMESPACE} \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
READY=$(kubectl get deploy wordpress -n ${NAMESPACE} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

[ "${READY}" = "${DESIRED}" ] && ok "${READY}/${DESIRED} replicas Ready" || \
  fail "${READY}/${DESIRED} replicas Ready"

# Init containers status
info "Statut des init containers (dernier pod) :"
WP_POD=$(kubectl get pods -n ${NAMESPACE} -l app=wordpress \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${WP_POD}" ]; then
  kubectl get pod ${WP_POD} -n ${NAMESPACE} \
    -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{" → "}{.state}{"\n"}{end}' \
    2>/dev/null | sed 's/^/    /' || true
fi

# ─── 2. Connectivité HTTP ─────────────────────────────────────
header "2. Connectivité WordPress HTTP"

HTTP_HOME=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://${NODE_IP}:30080/" 2>/dev/null || echo "000")
[ "${HTTP_HOME}" = "200" ] || [ "${HTTP_HOME}" = "301" ] || [ "${HTTP_HOME}" = "302" ] && \
  ok "Homepage : HTTP ${HTTP_HOME}" || fail "Homepage : HTTP ${HTTP_HOME}"

HTTP_ADMIN=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://${NODE_IP}:30080/wp-admin/" 2>/dev/null || echo "000")
[ "${HTTP_ADMIN}" = "200" ] || [ "${HTTP_ADMIN}" = "302" ] && \
  ok "wp-admin : HTTP ${HTTP_ADMIN}" || fail "wp-admin : HTTP ${HTTP_ADMIN}"

HTTP_LOGIN=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://${NODE_IP}:30080/wp-login.php" 2>/dev/null || echo "000")
[ "${HTTP_LOGIN}" = "200" ] && ok "wp-login.php : HTTP ${HTTP_LOGIN}" || \
  fail "wp-login.php : HTTP ${HTTP_LOGIN}"

# Test REST API (indicateur que WordPress fonctionne correctement)
REST_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://${NODE_IP}:30080/wp-json/wp/v2/" 2>/dev/null || echo "000")
[ "${REST_CODE}" = "200" ] && ok "REST API : HTTP ${REST_CODE}" || \
  warn "REST API : HTTP ${REST_CODE} (normal si non configuré)"

# ─── 3. Redis Object Cache ────────────────────────────────────
header "3. Redis Object Cache"

# Vérifier via WP-CLI dans un pod WordPress
WP_POD=$(kubectl get pods -n ${NAMESPACE} -l app=wordpress \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${WP_POD}" ]; then
  REDIS_STATUS=$(kubectl exec -n ${NAMESPACE} ${WP_POD} \
    -- wp redis status --allow-root --path=/var/www/html 2>/dev/null || echo "unknown")
  echo "    ${REDIS_STATUS}" | head -5

  # Vérifier que object-cache.php existe (drop-in actif)
  OC_EXISTS=$(kubectl exec -n ${NAMESPACE} ${WP_POD} \
    -- test -f /var/www/html/wp-content/object-cache.php 2>/dev/null && \
    echo "yes" || echo "no")
  [ "${OC_EXISTS}" = "yes" ] && ok "object-cache.php drop-in : présent" || \
    fail "object-cache.php drop-in : absent (wp redis enable non exécuté ?)"
else
  warn "Aucun pod WordPress Running trouvé"
fi

# Test direct Redis depuis le pod
if [ -n "${WP_POD}" ]; then
  REDIS_PING=$(kubectl exec -n ${NAMESPACE} ${WP_POD} \
    -- sh -c "redis-cli -h redis-sentinel-master-service -p 6379 \
    -a 'RedisSent!n3l2024' ping 2>/dev/null" 2>/dev/null || echo "FAIL")
  [ "${REDIS_PING}" = "PONG" ] && \
    ok "Connexion Redis master depuis pod WP : PONG" || \
    warn "Connexion Redis directe : ${REDIS_PING}"
fi

# ─── 4. MinIO / WP Offload Media ─────────────────────────────
header "4. MinIO — WP Offload Media"

# Test connectivité API MinIO depuis un pod WordPress
if [ -n "${WP_POD}" ]; then
  MINIO_CODE=$(kubectl exec -n ${NAMESPACE} ${WP_POD} \
    -- sh -c "wget -q -O /dev/null \
    http://minio-tenant-hl.wordpress-ha.svc.cluster.local:9000/minio/health/live \
    2>&1; echo \$?" 2>/dev/null || echo "1")
  [ "${MINIO_CODE}" = "0" ] && \
    ok "Accès MinIO API depuis pod WP : OK" || \
    warn "Accès MinIO API : ${MINIO_CODE}"
fi

# Vérifier plugin actif
if [ -n "${WP_POD}" ]; then
  OFFLOAD_ACTIVE=$(kubectl exec -n ${NAMESPACE} ${WP_POD} \
    -- wp plugin is-active amazon-s3-and-cloudfront \
    --allow-root --path=/var/www/html 2>/dev/null && \
    echo "actif" || echo "inactif")
  [ "${OFFLOAD_ACTIVE}" = "actif" ] && \
    ok "Plugin WP Offload Media Lite : actif" || \
    fail "Plugin WP Offload Media Lite : ${OFFLOAD_ACTIVE}"
fi

# Vérifier bucket accessible depuis l'extérieur
BUCKET_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 5 "http://${NODE_IP}:30900/minio/health/live" 2>/dev/null || echo "000")
[ "${BUCKET_CODE}" = "200" ] && ok "API S3 NodePort 30900 : HTTP ${BUCKET_CODE}" || \
  fail "API S3 NodePort 30900 : HTTP ${BUCKET_CODE}"

# ─── 5. MySQL ─────────────────────────────────────────────────
header "5. MySQL InnoDB Cluster"

MYSQL_STATUS=$(kubectl get innodbcluster mycluster -n ${NAMESPACE} \
  -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "unknown")
[ "${MYSQL_STATUS}" = "ONLINE" ] && ok "InnoDB Cluster : ONLINE" || \
  fail "InnoDB Cluster : ${MYSQL_STATUS}"

kubectl get pods -n ${NAMESPACE} \
  -l mysql.oracle.com/cluster=mycluster 2>/dev/null | tail -5 || true

# ─── 6. HPA ───────────────────────────────────────────────────
header "6. HorizontalPodAutoscaler"
kubectl get hpa wordpress-hpa -n ${NAMESPACE} 2>/dev/null || \
  warn "HPA non trouvé (metrics-server requis)"

# ─── 7. PDB ───────────────────────────────────────────────────
header "7. PodDisruptionBudget"
kubectl get pdb wordpress-pdb -n ${NAMESPACE} 2>/dev/null || \
  warn "PDB non trouvé"

# ─── 8. Tests de scaling ──────────────────────────────────────
header "8. Tests de scaling (manuel)"
echo ""
echo -e "  ${YELLOW}Scale up (4 replicas) :${NC}"
echo "  kubectl scale deployment/wordpress -n ${NAMESPACE} --replicas=4"
echo "  kubectl get pods -n ${NAMESPACE} -l app=wordpress -w"
echo ""
echo -e "  ${YELLOW}Scale down (2 replicas) :${NC}"
echo "  kubectl scale deployment/wordpress -n ${NAMESPACE} --replicas=2"
echo ""
echo -e "  ${YELLOW}Surveiller le HPA :${NC}"
echo "  kubectl get hpa wordpress-hpa -n ${NAMESPACE} -w"
echo ""

# ─── 9. Tests de résilience ───────────────────────────────────
header "9. Tests de résilience (simulation de pannes)"
echo ""
echo -e "  ${YELLOW}Test 1 — Panne d'un pod WordPress :${NC}"
echo "  kubectl delete pod \$(kubectl get pods -n ${NAMESPACE} -l app=wordpress \\"
echo "    -o jsonpath='{.items[0].metadata.name}') -n ${NAMESPACE}"
echo "  # WordPress doit rester accessible via les autres pods"
echo ""
echo -e "  ${YELLOW}Test 2 — Failover MySQL :${NC}"
echo "  kubectl delete pod mycluster-0 -n ${NAMESPACE}"
echo "  # Un secondary devient primary en < 30s"
echo ""
echo -e "  ${YELLOW}Test 3 — Failover Redis :${NC}"
echo "  kubectl delete pod redis-sentinel-0 -n ${NAMESPACE}"
echo "  # Un replica devient master en < 15s"
echo ""
echo -e "  ${YELLOW}Test 4 — Panne d'un pod MinIO :${NC}"
echo "  kubectl delete pod minio-tenant-pool-0-0 -n ${NAMESPACE}"
echo "  # MinIO reste accessible grâce à EC:4"
echo ""

# ─── URLs de la stack ─────────────────────────────────────────
header "Récapitulatif URLs"
echo ""
echo -e "  ${GREEN}WordPress Frontend${NC}  : http://${NODE_IP}:30080"
echo -e "  ${GREEN}WordPress Admin${NC}     : http://${NODE_IP}:30080/wp-admin  (admin / WPadmin!2024)"
echo -e "  ${GREEN}MinIO Console${NC}       : http://${NODE_IP}:30901  (minio / MinIOr00t!2024)"
echo -e "  ${GREEN}MinIO API S3${NC}        : http://${NODE_IP}:30900"
echo -e "  ${GREEN}Redis master${NC}        : ${NODE_IP}:30379"
echo -e "  ${GREEN}Redis Sentinel${NC}      : ${NODE_IP}:30380"
echo -e "  ${GREEN}MySQL R/W${NC}           : ${NODE_IP}:30306"
echo ""

# ─── Événements warnings ──────────────────────────────────────
header "Événements warnings récents"
kubectl get events -n ${NAMESPACE} \
  --sort-by='.lastTimestamp' \
  --field-selector=type=Warning 2>/dev/null | tail -10 || true
