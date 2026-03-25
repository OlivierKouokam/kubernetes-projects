#!/usr/bin/env bash
# =============================================================
# verify-redis.sh — Vérification complète du cluster Redis HA
#
# Vérifie :
#   1. Opérateur Redis
#   2. Pods Redis (master / replicas / sentinels)
#   3. PVCs
#   4. Services
#   5. Connectivité Redis master + réplication
#   6. Interrogation Sentinels
#   7. Test de failover automatique
# =============================================================

set -uo pipefail

NAMESPACE="wordpress-ha"
OPERATOR_NS="redis-operator"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
REDIS_PASS="RedisSent!n3l2024"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

header() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
info()   { echo -e "  ${BLUE}→${NC} $*"; }

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Redis HA — Rapport de vérification      ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# ─── 1. Opérateur ─────────────────────────────────────────────
header "1. Redis Operator (OT-SCNG)"
OP_READY=$(kubectl get deploy redis-operator -n ${OPERATOR_NS} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
[ "${OP_READY}" = "1" ] && ok "Redis Operator : Running" || fail "Redis Operator : problème (ready=${OP_READY})"
kubectl get pods -n ${OPERATOR_NS} 2>/dev/null || true

# ─── 2. CRDs ──────────────────────────────────────────────────
header "2. Custom Resource Definitions"
kubectl get crd | grep redis.opstreelabs.in 2>/dev/null || fail "CRDs Redis non trouvés"

# ─── 3. RedisSentinel CR ──────────────────────────────────────
header "3. RedisSentinel Custom Resource"
kubectl get redissentinel -n ${NAMESPACE} 2>/dev/null || fail "Aucun RedisSentinel trouvé"

# ─── 4. Pods ──────────────────────────────────────────────────
header "4. Pods Redis + Sentinel"
kubectl get pods -n ${NAMESPACE} -l app=redis-sentinel -o wide 2>/dev/null || true
echo ""

# Identifier les rôles
info "Rôles détectés :"
for pod in $(kubectl get pods -n ${NAMESPACE} -l app=redis-sentinel \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  ROLE=$(kubectl get pod ${pod} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.labels.redis-role}' 2>/dev/null || echo "unknown")
  echo -e "    ${pod} → ${YELLOW}${ROLE}${NC}"
done

# ─── 5. PVCs ──────────────────────────────────────────────────
header "5. Persistent Volume Claims"
kubectl get pvc -n ${NAMESPACE} | grep -i redis 2>/dev/null || true
PENDING=$(kubectl get pvc -n ${NAMESPACE} \
  --field-selector=status.phase!=Bound \
  -o name 2>/dev/null | grep -i redis | wc -l)
[ "${PENDING}" = "0" ] && ok "Tous les PVCs Redis sont Bound" || fail "${PENDING} PVC(s) Redis non Bound"

# ─── 6. Services ──────────────────────────────────────────────
header "6. Services Redis"
kubectl get svc -n ${NAMESPACE} | grep -i redis 2>/dev/null || true

# ─── 7. Test connectivité Redis ───────────────────────────────
header "7. Test connectivité"

if command -v redis-cli &>/dev/null; then

  # Ping master via NodePort
  PING=$(redis-cli -h ${NODE_IP} -p 30379 -a "${REDIS_PASS}" \
    --no-auth-warning ping 2>/dev/null || echo "FAIL")
  [ "${PING}" = "PONG" ] && ok "Ping master (NodePort 30379) : PONG" || fail "Ping master : FAIL"

  # Info réplication
  info "Info réplication :"
  redis-cli -h ${NODE_IP} -p 30379 -a "${REDIS_PASS}" \
    --no-auth-warning INFO replication 2>/dev/null | \
    grep -E "^(role|connected_slaves|master_host|master_link_status|slave[0-9])" | \
    sed 's/^/    /'

  # Test écriture / lecture
  redis-cli -h ${NODE_IP} -p 30379 -a "${REDIS_PASS}" \
    --no-auth-warning SET wp:test:key "phase2-ok" EX 60 &>/dev/null && \
    VAL=$(redis-cli -h ${NODE_IP} -p 30379 -a "${REDIS_PASS}" \
      --no-auth-warning GET wp:test:key 2>/dev/null) && \
    [ "${VAL}" = "phase2-ok" ] && \
    ok "Écriture/lecture Redis : OK (SET/GET)" || \
    fail "Écriture/lecture Redis : ÉCHEC"

  # Test Sentinel
  info "Interrogation Sentinels (NodePort 30380) :"
  MASTER_ADDR=$(redis-cli -h ${NODE_IP} -p 30380 \
    --no-auth-warning \
    SENTINEL get-master-addr-by-name mymaster 2>/dev/null || echo "FAIL")
  if [ "${MASTER_ADDR}" != "FAIL" ] && [ -n "${MASTER_ADDR}" ]; then
    ok "Sentinel répond — master actuel : ${MASTER_ADDR}"
  else
    fail "Sentinel ne répond pas ou mymaster introuvable"
  fi

  info "Sentinels connus :"
  redis-cli -h ${NODE_IP} -p 30380 \
    --no-auth-warning \
    SENTINEL sentinels mymaster 2>/dev/null | \
    grep -E "^(name|ip|port|flags)" | sed 's/^/    /' || true

  info "Replicas connus :"
  redis-cli -h ${NODE_IP} -p 30380 \
    --no-auth-warning \
    SENTINEL replicas mymaster 2>/dev/null | \
    grep -E "^(name|ip|port|flags|master-link-status)" | sed 's/^/    /' || true

else
  warn "redis-cli non installé — tests via pod temporaire :"
  echo ""
  echo "  kubectl run redis-test --image=redis:7.2-alpine --rm -it --restart=Never \\"
  echo "    -n ${NAMESPACE} \\"
  echo "    -- redis-cli -h redis-sentinel-master-service -p 6379 \\"
  echo "       -a '${REDIS_PASS}' INFO replication"
fi

# ─── 8. Test de failover ──────────────────────────────────────
header "8. Test de failover Sentinel (optionnel)"
echo ""
echo -e "  ${YELLOW}Pour tester le failover automatique :${NC}"
echo ""
echo "  # 1. Identifier le pod master actuel"
echo "  kubectl get pods -n ${NAMESPACE} -l redis-role=master"
echo ""
echo "  # 2. Supprimer le master (simule une panne)"
echo "  kubectl delete pod redis-sentinel-0 -n ${NAMESPACE}  # adapter le nom"
echo ""
echo "  # 3. Observer la réélection Sentinel (< 15s)"
echo "  watch redis-cli -h ${NODE_IP} -p 30380 SENTINEL get-master-addr-by-name mymaster"
echo ""
echo "  # 4. Vérifier que le nouveau master accepte les écritures"
echo "  redis-cli -h ${NODE_IP} -p 30379 -a '${REDIS_PASS}' SET test:failover ok"
echo ""
echo "  # 5. Observer le pod supprimé redémarrer en replica"
echo "  kubectl get pods -n ${NAMESPACE} -l app=redis-sentinel -w"
echo ""

# ─── 9. Endpoints pour WordPress ──────────────────────────────
header "9. Endpoints internes pour WordPress (Phase 4)"
echo ""
echo -e "  Plugin Redis Object Cache — config wp-config.php :"
echo ""
echo "  define('WP_REDIS_CLIENT', 'predis');"
echo "  define('WP_REDIS_SENTINEL', 'mymaster');"
echo "  define('WP_REDIS_SENTINELS', ["
echo "    'tcp://redis-sentinel-service:26379',"
echo "  ]);"
echo "  define('WP_REDIS_PASSWORD', 'RedisSent!n3l2024');"
echo "  define('WP_REDIS_DATABASE', 0);"
echo ""

# ─── Événements ───────────────────────────────────────────────
header "Événements récents (warnings uniquement)"
kubectl get events -n ${NAMESPACE} \
  --sort-by='.lastTimestamp' \
  --field-selector=type=Warning 2>/dev/null | tail -10 || true
