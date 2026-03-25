#!/usr/bin/env bash
# =============================================================
# Phase 1 — Déploiement MySQL HA (InnoDB Cluster + MySQL Operator)
#
# Prérequis :
#   - kubectl configuré sur le cluster cible
#   - helm 3.x installé
#   - StorageClass "example-nfs" disponible et fonctionnelle
#   - Namespace wordpress-ha créé (ou lancer le step 1 ci-dessous)
#
# Usage :
#   chmod +x deploy-mysql.sh
#   ./deploy-mysql.sh
#
# Ou étape par étape en copiant chaque bloc dans le terminal.
# =============================================================

set -euo pipefail

# ── Couleurs pour les logs ────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Variables ─────────────────────────────────────────────────
NAMESPACE="wordpress-ha"
CLUSTER_NAME="mycluster"
OPERATOR_NAMESPACE="mysql-operator"
HELM_REPO_NAME="mysql-operator"
HELM_REPO_URL="https://mysql.github.io/mysql-operator/"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 1 — Namespace
# ─────────────────────────────────────────────────────────────
info "Étape 1/7 — Création du namespace ${NAMESPACE}..."
kubectl apply -f ../namespace.yaml
success "Namespace ${NAMESPACE} prêt"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 2 — Ajout du repo Helm MySQL Operator
# ─────────────────────────────────────────────────────────────
info "Étape 2/7 — Ajout du repo Helm MySQL Operator..."
helm repo add ${HELM_REPO_NAME} ${HELM_REPO_URL} 2>/dev/null || true
helm repo update
success "Repo Helm MySQL Operator ajouté"

# Vérification des charts disponibles
info "Charts disponibles :"
helm search repo mysql-operator

# ─────────────────────────────────────────────────────────────
# ÉTAPE 3 — Installation du MySQL Operator
# ─────────────────────────────────────────────────────────────
info "Étape 3/7 — Installation du MySQL Operator..."

# L'opérateur tourne dans son propre namespace dédié
kubectl create namespace ${OPERATOR_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install mysql-operator ${HELM_REPO_NAME}/mysql-operator \
  --namespace ${OPERATOR_NAMESPACE} \
  --values operator/values-mysql-operator.yaml \
  --wait \
  --timeout 5m

success "MySQL Operator installé dans namespace ${OPERATOR_NAMESPACE}"

# Attente que l'opérateur soit complètement prêt
info "Attente du démarrage de l'opérateur..."
kubectl rollout status deployment/mysql-operator -n ${OPERATOR_NAMESPACE} --timeout=3m
success "MySQL Operator opérationnel"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 4 — Secrets MySQL
# ─────────────────────────────────────────────────────────────
info "Étape 4/7 — Application des Secrets MySQL..."

# ⚠️  IMPORTANT : Modifier les mots de passe dans secrets/mysql-secret.yaml
# avant d'appliquer en production !
warn "Vérifiez les mots de passe dans secrets/mysql-secret.yaml avant de continuer"
warn "Mots de passe par défaut : rootPassword=WPr00tS3cur3!2024 / wpPassword=WPdbP@ss2024!"

kubectl apply -f secrets/mysql-secret.yaml
success "Secret mysql-credentials créé dans namespace ${NAMESPACE}"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 5 — Déploiement du cluster InnoDB
# ─────────────────────────────────────────────────────────────
info "Étape 5/7 — Déploiement du cluster InnoDB (${CLUSTER_NAME})..."

# Le chart mysql-innodbcluster crée :
#   - 3 StatefulSets MySQL (primary + 2 secondary)
#   - 2 Deployments MySQLRouter
#   - Services ClusterIP internes + NodePort test
#   - 3 PVCs via StorageClass example-nfs

helm upgrade --install ${CLUSTER_NAME} ${HELM_REPO_NAME}/mysql-innodbcluster \
  --namespace ${NAMESPACE} \
  --values cluster/values-innodbcluster.yaml \
  --set credentials.root.password="" \
  --set existingSecret=mysql-credentials \
  --wait \
  --timeout 15m    # Le cluster InnoDB prend du temps à s'initialiser

success "Chart InnoDB Cluster déployé"

# ─────────────────────────────────────────────────────────────
# ÉTAPE 6 — Attente que le cluster soit ONLINE
# ─────────────────────────────────────────────────────────────
info "Étape 6/7 — Attente que le cluster InnoDB soit ONLINE..."
info "Cela peut prendre 5 à 10 minutes (Group Replication + bootstrap)..."

# Boucle de vérification du statut
MAX_WAIT=600   # 10 minutes max
ELAPSED=0
INTERVAL=15

while true; do
  STATUS=$(kubectl get innodbcluster ${CLUSTER_NAME} -n ${NAMESPACE} \
    -o jsonpath='{.status.cluster.status}' 2>/dev/null || echo "unknown")

  info "Statut cluster : ${STATUS} (${ELAPSED}s écoulées)"

  if [ "${STATUS}" = "ONLINE" ]; then
    success "Cluster InnoDB ${CLUSTER_NAME} est ONLINE !"
    break
  fi

  if [ ${ELAPSED} -ge ${MAX_WAIT} ]; then
    error "Timeout — Le cluster n'est pas ONLINE après ${MAX_WAIT}s"
  fi

  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

# ─────────────────────────────────────────────────────────────
# ÉTAPE 7 — Init base WordPress + NodePort test
# ─────────────────────────────────────────────────────────────
info "Étape 7/7 — Initialisation base WordPress..."

kubectl apply -f cluster/mysql-initdb-configmap.yaml
kubectl apply -f cluster/mysql-initdb-job.yaml

info "Attente du Job d'initialisation..."
kubectl wait --for=condition=complete job/mysql-initdb \
  -n ${NAMESPACE} \
  --timeout=5m

success "Base WordPress créée !"

# Exposition NodePort pour tests
info "Application du service NodePort de test..."
kubectl apply -f cluster/mysql-nodeport-test.yaml

# ─────────────────────────────────────────────────────────────
# RÉCAPITULATIF
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Phase 1 — MySQL HA déployé avec succès !         ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo -e "${BLUE}Statut du cluster :${NC}"
kubectl get innodbcluster -n ${NAMESPACE}
echo ""
kubectl get pods -n ${NAMESPACE} -l mysql.oracle.com/cluster=${CLUSTER_NAME}
echo ""

echo -e "${BLUE}PVCs créés :${NC}"
kubectl get pvc -n ${NAMESPACE}
echo ""

echo -e "${BLUE}Services exposés :${NC}"
kubectl get svc -n ${NAMESPACE}
echo ""

echo -e "${YELLOW}━━━ Tests de connexion ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Connexion R/W (root) :"
echo -e "  ${GREEN}mysql -h ${NODE_IP} -P 30306 -u root -pWPr00tS3cur3!2024${NC}"
echo ""
echo -e "  Connexion R/W (wordpress) :"
echo -e "  ${GREEN}mysql -h ${NODE_IP} -P 30306 -u wordpress -pWPdbP@ss2024! wordpress_db${NC}"
echo ""
echo -e "  Connexion R/O (réplication) :"
echo -e "  ${GREEN}mysql -h ${NODE_IP} -P 30307 -u wordpress -pWPdbP@ss2024! wordpress_db${NC}"
echo ""
echo -e "${YELLOW}━━━ Vérification InnoDB Group Replication ━━━━━━━━━${NC}"
echo ""
echo -e "  Dans la console MySQL :"
echo -e "  ${GREEN}SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE"
echo -e "  FROM performance_schema.replication_group_members;${NC}"
echo ""
echo -e "${YELLOW}━━━ Prochaine étape ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Phase 2 : Redis HA (OT-SCNG Operator)"
echo ""
