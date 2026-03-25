#!/usr/bin/env bash
# =============================================================
# verify-mysql.sh — Vérification complète du cluster MySQL HA
#
# Utilisation :
#   chmod +x verify-mysql.sh
#   ./verify-mysql.sh
#
# Ce script vérifie :
#   1. Statut de l'opérateur MySQL
#   2. Statut du cluster InnoDB
#   3. Statut des pods (primary / secondary)
#   4. Statut des PVCs
#   5. Connectivité MySQLRouter
#   6. Membres du Group Replication
#   7. Test de failover (optionnel)
# =============================================================

set -uo pipefail

NAMESPACE="wordpress-ha"
CLUSTER_NAME="mycluster"
OPERATOR_NS="mysql-operator"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

header() { echo -e "\n${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
info()   { echo -e "  ${BLUE}→${NC} $*"; }

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   MySQL HA — Rapport de vérification      ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# ─── 1. Opérateur ─────────────────────────────────────────────
header "1. MySQL Operator"
OP_STATUS=$(kubectl get deploy mysql-operator -n ${OPERATOR_NS} \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${OP_STATUS}" = "1" ]; then
  ok "MySQL Operator : Running (1/1)"
else
  fail "MySQL Operator : problème détecté (readyReplicas=${OP_STATUS})"
fi
kubectl get pods -n ${OPERATOR_NS} 2>/dev/null || true

# ─── 2. Cluster InnoDB ────────────────────────────────────────
header "2. Statut cluster InnoDB"
kubectl get innodbcluster -n ${NAMESPACE} 2>/dev/null || \
  fail "Aucun InnoDBCluster trouvé dans namespace ${NAMESPACE}"

CLUSTER_STATUS=$(kubectl get innodbcluster ${CLUSTER_NAME} -n ${NAMESPACE} \
  -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "unknown")

if [ "${CLUSTER_STATUS}" = "ONLINE" ]; then
  ok "Cluster status : ONLINE"
else
  fail "Cluster status : ${CLUSTER_STATUS}"
  info "Détail :"
  kubectl describe innodbcluster ${CLUSTER_NAME} -n ${NAMESPACE} 2>/dev/null | \
    grep -A5 "Status:" || true
fi

# ─── 3. Pods ──────────────────────────────────────────────────
header "3. Pods MySQL + MySQLRouter"
kubectl get pods -n ${NAMESPACE} \
  -l mysql.oracle.com/cluster=${CLUSTER_NAME} \
  -o wide 2>/dev/null || true

echo ""
# Identifier qui est le PRIMARY
info "Rôles dans le cluster :"
for pod in $(kubectl get pods -n ${NAMESPACE} \
  -l mysql.oracle.com/cluster=${CLUSTER_NAME} \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  ROLE=$(kubectl get pod ${pod} -n ${NAMESPACE} \
    -o jsonpath='{.metadata.labels.mysql\.oracle\.com/cluster-role}' 2>/dev/null || echo "unknown")
  echo -e "    ${pod} → ${YELLOW}${ROLE}${NC}"
done

# ─── 4. PVCs ──────────────────────────────────────────────────
header "4. Persistent Volume Claims"
kubectl get pvc -n ${NAMESPACE} 2>/dev/null || true

PVC_PENDING=$(kubectl get pvc -n ${NAMESPACE} \
  --field-selector=status.phase!=Bound \
  -o name 2>/dev/null | wc -l)
if [ "${PVC_PENDING}" = "0" ]; then
  ok "Tous les PVCs sont en état Bound"
else
  fail "${PVC_PENDING} PVC(s) non Bound — vérifier le NFS provisioner"
fi

# ─── 5. Services ──────────────────────────────────────────────
header "5. Services"
kubectl get svc -n ${NAMESPACE} 2>/dev/null || true

# ─── 6. Test de connectivité ──────────────────────────────────
header "6. Test de connectivité MySQLRouter"
if command -v mysql &>/dev/null; then
  info "Test connexion R/W via NodePort ${NODE_IP}:30306..."
  mysql -h ${NODE_IP} -P 30306 -u root -pWPr00tS3cur3!2024 \
    --connect-timeout=5 \
    --ssl-mode=PREFERRED \
    -e "SELECT 'Connexion R/W OK' AS status;" 2>/dev/null && \
    ok "Connexion R/W : OK" || fail "Connexion R/W : ÉCHEC"

  info "Vérification des membres du Group Replication..."
  mysql -h ${NODE_IP} -P 30306 -u root -pWPr00tS3cur3!2024 \
    --connect-timeout=5 \
    --ssl-mode=PREFERRED \
    -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE \
        FROM performance_schema.replication_group_members;" 2>/dev/null || \
    fail "Impossible de lire les membres du groupe"

  info "Vérification base wordpress_db..."
  mysql -h ${NODE_IP} -P 30306 -u wordpress -pWPdbP@ss2024! \
    --connect-timeout=5 \
    --ssl-mode=PREFERRED \
    -e "SHOW DATABASES; SELECT USER();" wordpress_db 2>/dev/null && \
    ok "Connexion utilisateur wordpress : OK" || \
    fail "Connexion utilisateur wordpress : ÉCHEC"
else
  warn "Client mysql non installé sur ce système"
  info "Test manuel :"
  echo "  mysql -h ${NODE_IP} -P 30306 -u root -pWPr00tS3cur3!2024"
  info "Ou via un pod temporaire :"
  echo "  kubectl run mysql-client --image=mysql:9.1 --rm -it --restart=Never -n ${NAMESPACE} \\"
  echo "    -- mysql -h mycluster-router-service -P 6446 -u root -pWPr00tS3cur3!2024"
fi

# ─── 7. Logs récents ──────────────────────────────────────────
header "7. Derniers événements namespace ${NAMESPACE}"
kubectl get events -n ${NAMESPACE} \
  --sort-by='.lastTimestamp' \
  --field-selector=type!=Normal 2>/dev/null | tail -10 || true

echo ""
echo -e "${CYAN}━━━ Commandes de diagnostic avancé ━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  # Logs d'un pod MySQL :"
echo "  kubectl logs -n ${NAMESPACE} ${CLUSTER_NAME}-0 -c mysql -f"
echo ""
echo "  # Logs MySQLRouter :"
echo "  kubectl logs -n ${NAMESPACE} -l component=mysqlrouter -f"
echo ""
echo "  # Logs de l'opérateur :"
echo "  kubectl logs -n ${OPERATOR_NS} deployment/mysql-operator -f"
echo ""
echo "  # Shell interactif MySQL (sans client local) :"
echo "  kubectl run mysql-client --image=mysql:9.1 --rm -it --restart=Never -n ${NAMESPACE} \\"
echo "    -- mysql -h mycluster-router-service -P 6446 -u root -pWPr00tS3cur3!2024"
echo ""
echo "  # Simuler un failover (supprimer le primary) :"
echo "  kubectl delete pod ${CLUSTER_NAME}-0 -n ${NAMESPACE}"
echo "  # Vérifier la réélection :"
echo "  kubectl get pods -n ${NAMESPACE} -w"
echo ""
