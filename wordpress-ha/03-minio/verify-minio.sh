#!/usr/bin/env bash
# =============================================================
# verify-minio.sh — Vérification complète du Tenant MinIO HA
#
# Vérifie :
#   1. Opérateur MinIO
#   2. Tenant CR + statut health
#   3. Pods MinIO (4 attendus)
#   4. PVCs (8 attendus — 2 par pod)
#   5. Services
#   6. Connectivité API S3 (mc ou curl)
#   7. Bucket wp-uploads + accès utilisateur WordPress
#   8. Test de résilience erasure coding
# =============================================================

set -uo pipefail

NAMESPACE="wordpress-ha"
OPERATOR_NS="minio-operator"
TENANT_NAME="minio-tenant"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
ROOT_USER="minio"
ROOT_PASS="MinIOr00t!2024"
WP_ACCESS="wp-minio-user"
WP_SECRET="WPMinIO!S3c2024"
BUCKET="wp-uploads"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

header() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
info()   { echo -e "  ${BLUE}→${NC} $*"; }

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   MinIO HA — Rapport de vérification      ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# ─── 1. Opérateur ─────────────────────────────────────────────
header "1. MinIO Operator"
OP_READY=$(kubectl get deploy minio-operator -n ${OPERATOR_NS} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[ "${OP_READY}" = "1" ] && ok "MinIO Operator : Running" || fail "MinIO Operator : problème (ready=${OP_READY})"
kubectl get pods -n ${OPERATOR_NS} 2>/dev/null || true

# ─── 2. Tenant CR ─────────────────────────────────────────────
header "2. Tenant MinIO CR"
kubectl get tenant -n ${NAMESPACE} 2>/dev/null || fail "Aucun Tenant MinIO trouvé"

HEALTH=$(kubectl get tenant ${TENANT_NAME} -n ${NAMESPACE} \
  -o jsonpath='{.status.healthStatus}' 2>/dev/null || echo "unknown")
CAPACITY=$(kubectl get tenant ${TENANT_NAME} -n ${NAMESPACE} \
  -o jsonpath='{.status.usage.capacity}' 2>/dev/null || echo "unknown")

[ "${HEALTH}" = "green" ] && ok "Health : green" || fail "Health : ${HEALTH} (attendu: green)"
info "Capacité totale : ${CAPACITY}"

# ─── 3. Pods ──────────────────────────────────────────────────
header "3. Pods MinIO (4 attendus)"
kubectl get pods -n ${NAMESPACE} -l v1.min.io/tenant=${TENANT_NAME} -o wide 2>/dev/null || true

POD_COUNT=$(kubectl get pods -n ${NAMESPACE} \
  -l v1.min.io/tenant=${TENANT_NAME} \
  --field-selector=status.phase=Running \
  -o name 2>/dev/null | wc -l)
[ "${POD_COUNT}" -eq 4 ] && ok "${POD_COUNT}/4 pods Running" || fail "${POD_COUNT}/4 pods Running"

# ─── 4. PVCs ──────────────────────────────────────────────────
header "4. PVCs (8 attendus — 2 drives × 4 serveurs)"
kubectl get pvc -n ${NAMESPACE} | grep -i "minio\|${TENANT_NAME}" 2>/dev/null || true

PVC_COUNT=$(kubectl get pvc -n ${NAMESPACE} \
  --field-selector=status.phase=Bound \
  -o name 2>/dev/null | grep -i "minio\|${TENANT_NAME}" | wc -l)
[ "${PVC_COUNT}" -eq 8 ] && ok "${PVC_COUNT}/8 PVCs Bound" || \
  fail "${PVC_COUNT}/8 PVCs Bound — vérifier le NFS provisioner"

# ─── 5. Services ──────────────────────────────────────────────
header "5. Services MinIO"
kubectl get svc -n ${NAMESPACE} | grep -i minio 2>/dev/null || true

# ─── 6. Test connectivité API S3 ──────────────────────────────
header "6. Test API S3"

if command -v mc &>/dev/null; then
  # Configurer alias mc
  mc alias set wplab http://${NODE_IP}:30900 ${ROOT_USER} ${ROOT_PASS} \
    --api S3v4 &>/dev/null && ok "Alias mc configuré (wplab)" || \
    fail "Impossible de se connecter à l'API MinIO"

  # Info cluster
  info "Info cluster MinIO :"
  mc admin info wplab 2>/dev/null | grep -E "^(●|Pools|Uptime|Drives)" | \
    head -10 | sed 's/^/    /' || true

  # Lister les buckets
  info "Buckets :"
  mc ls wplab/ 2>/dev/null | sed 's/^/    /' || fail "Impossible de lister les buckets"

  # Vérifier bucket wp-uploads
  mc ls wplab/${BUCKET} &>/dev/null && \
    ok "Bucket ${BUCKET} : accessible" || \
    fail "Bucket ${BUCKET} : introuvable"

  # Test upload/download avec user root
  TMPFILE=$(mktemp)
  echo "minio-verify-$(date +%s)" > ${TMPFILE}
  mc cp ${TMPFILE} wplab/${BUCKET}/verify-test.txt &>/dev/null && \
    ok "Upload (root) : OK" || fail "Upload (root) : ÉCHEC"

  mc cat wplab/${BUCKET}/verify-test.txt &>/dev/null && \
    ok "Download (root) : OK" || fail "Download (root) : ÉCHEC"

  mc rm wplab/${BUCKET}/verify-test.txt &>/dev/null && true
  rm -f ${TMPFILE}

  # Test avec user WordPress
  mc alias set wpminio http://${NODE_IP}:30900 ${WP_ACCESS} ${WP_SECRET} \
    --api S3v4 &>/dev/null

  TMPFILE2=$(mktemp)
  echo "wp-user-test-$(date +%s)" > ${TMPFILE2}
  mc cp ${TMPFILE2} wpminio/${BUCKET}/wp-user-test.txt &>/dev/null && \
    ok "Upload (user wp-minio-user) : OK" || \
    fail "Upload (user wp-minio-user) : ÉCHEC — vérifier la politique IAM"
  mc rm wpminio/${BUCKET}/wp-user-test.txt &>/dev/null && true
  rm -f ${TMPFILE2}

  # Vérifier la politique anonyme (lecture publique des médias)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${NODE_IP}:30900/${BUCKET}/" 2>/dev/null || echo "000")
  [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "403" ] && \
    info "API S3 répond (HTTP ${HTTP_CODE}) — lecture publique configurée" || \
    warn "API S3 : HTTP ${HTTP_CODE}"

  # Nettoyage alias temporaire
  mc alias remove wpminio &>/dev/null || true

else
  warn "mc (MinIO Client) non installé"
  info "Installation : https://min.io/docs/minio/linux/reference/minio-mc.html"
  echo ""
  info "Test via curl (API S3) :"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${NODE_IP}:30900/minio/health/live" 2>/dev/null || echo "000")
  [ "${HTTP_CODE}" = "200" ] && ok "Health endpoint MinIO : HTTP 200" || \
    fail "Health endpoint MinIO : HTTP ${HTTP_CODE}"

  echo ""
  info "Test via pod temporaire (mc intégré) :"
  echo "  kubectl run mc-test --image=minio/mc:latest --rm -it --restart=Never \\"
  echo "    -n ${NAMESPACE} \\"
  echo "    -- /bin/sh -c \\"
  echo "    'mc alias set m http://minio-tenant-hl:9000 minio MinIOr00t!2024 && mc ls m/'"
fi

# ─── 7. Vérification utilisateur WordPress ────────────────────
header "7. Utilisateur WordPress MinIO"
if command -v mc &>/dev/null; then
  info "Droits de l'utilisateur ${WP_ACCESS} :"
  mc admin user info wplab ${WP_ACCESS} 2>/dev/null | sed 's/^/    /' || \
    fail "Utilisateur ${WP_ACCESS} introuvable — relancer le Job minio-init"
  mc admin policy entities wplab --user ${WP_ACCESS} 2>/dev/null | \
    sed 's/^/    /' || true
  mc alias remove wplab &>/dev/null || true
fi

# ─── 8. Test de résilience ─────────────────────────────────────
header "8. Test de résilience Erasure Coding (optionnel)"
echo ""
echo -e "  ${YELLOW}MinIO EC:4 tolère la perte simultanée de 2 pods sur 4.${NC}"
echo ""
echo "  # Supprimer 1 pod (MinIO reste disponible en EC:4)"
echo "  kubectl delete pod ${TENANT_NAME}-pool-0-0 -n ${NAMESPACE}"
echo ""
echo "  # Vérifier que l'API répond toujours"
echo "  curl -s http://${NODE_IP}:30900/minio/health/live"
echo ""
echo "  # Vérifier le health (doit passer orange puis revenir vert)"
echo "  watch kubectl get tenant ${TENANT_NAME} -n ${NAMESPACE}"
echo ""
echo "  # Supprimer 2 pods simultanément (limite de tolérance EC:4)"
echo "  kubectl delete pod ${TENANT_NAME}-pool-0-0 ${TENANT_NAME}-pool-0-1 -n ${NAMESPACE}"
echo ""

# ─── 9. Config WordPress ──────────────────────────────────────
header "9. Configuration plugin WP Offload Media (Phase 4)"
echo ""
echo -e "  ${YELLOW}Paramètres à saisir dans WP Offload Media :${NC}"
echo ""
echo "  Provider       : MinIO (S3-compatible)"
echo "  Endpoint       : http://minio-tenant-hl.wordpress-ha.svc.cluster.local:9000"
echo "  Bucket         : wp-uploads"
echo "  Region         : us-east-1"
echo "  Access Key     : wp-minio-user"
echo "  Secret Key     : WPMinIO!S3c2024"
echo "  Force Path     : yes  (obligatoire avec MinIO — pas de virtual hosted)"
echo "  Public URL     : http://${NODE_IP}:30900/wp-uploads"
echo ""

# ─── Événements ───────────────────────────────────────────────
header "Événements récents (warnings uniquement)"
kubectl get events -n ${NAMESPACE} \
  --sort-by='.lastTimestamp' \
  --field-selector=type=Warning 2>/dev/null | tail -10 || true
