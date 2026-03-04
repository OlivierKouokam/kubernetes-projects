#!/bin/bash
# =============================================================================
#  install_kubernetes.sh
#  Déploiement automatisé d'un cluster Kubernetes 1.34 avec kubeadm
#
#  Appelé par Vagrant via config.vm.provision "shell"
#  Le script détecte le rôle du nœud via $HOSTNAME :
#    - "controlplane" → partie commune + init cluster + CNI + Dashboard
#    - "node*"        → partie commune + join cluster
#
#  Mécanisme de partage du join command :
#    Le controlplane écrit /vagrant/join_command.sh
#    Ce dossier est automatiquement partagé entre toutes les VMs par VirtualBox
#    Les workers lisent et exécutent ce fichier
#
#  Réseau :
#    Nœuds (VMs)   : 192.168.90.0/24   (réseau Vagrant / VirtualBox)
#    Pods (Calico)  : 10.244.0.0/16     (pas de chevauchement avec les VMs)
#    Services K8s   : 10.96.0.0/12      (défaut kubeadm)
# =============================================================================

set -euo pipefail
# set -e  : arrêt immédiat si une commande retourne un code non-zéro
# set -u  : erreur si une variable non définie est utilisée
# set -o pipefail : le pipe échoue si l'une des commandes du pipe échoue

# ─────────────────────────────────────────────────────────────────────────────
#  Couleurs pour les logs
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_section() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${CYAN}  $1${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Variables de configuration — modifier ici pour changer les versions
# ─────────────────────────────────────────────────────────────────────────────
K8S_VERSION="1.34"                          # version mineure (pour le repo apt)
K8S_EXACT_VERSION="v1.34.0"                # version exacte (pour kubeadm init)
CALICO_VERSION="v3.29.0"                   # version Calico CNI
MASTER_IP="192.168.90.10"                  # IP du controlplane
POD_CIDR="10.244.0.0/16"                   # CIDR réseau pods (≠ réseau VMs 192.168.90.x)
JOIN_FILE="/vagrant/join_command.sh"        # fichier partagé via VirtualBox shared folder
JOIN_TIMEOUT=300                            # secondes max d'attente du fichier join (5 min)

# ─────────────────────────────────────────────────────────────────────────────
#  Désactiver les prompts interactifs apt
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive

# =============================================================================
#  PARTIE COMMUNE — exécutée sur TOUS les nœuds (controlplane + workers)
# =============================================================================
common_setup() {

    # ── Étape 1 : Mise à jour du système ─────────────────────────────────────
    log_section "Étape 1/6 [COMMUN] Mise à jour du système"
    apt-get update
    apt-get upgrade -y
    log_info "Système mis à jour"

    # ── Étape 2 : /etc/hosts ─────────────────────────────────────────────────
    log_section "Étape 2/6 [COMMUN] Configuration /etc/hosts"
    # Vérification avant ajout pour éviter les doublons si le script est rejoué
    grep -qxF "192.168.90.10 controlplane" /etc/hosts || \
        echo "192.168.90.10 controlplane" >> /etc/hosts
    grep -qxF "192.168.90.11 node1"        /etc/hosts || \
        echo "192.168.90.11 node1"        >> /etc/hosts
    log_info "/etc/hosts :"
    grep -E "controlplane|node1" /etc/hosts

    # ── Étape 3 : Désactivation du swap ──────────────────────────────────────
    log_section "Étape 3/6 [COMMUN] Désactivation du swap"
    # Désactivation immédiate
    swapoff -a
    # Désactivation permanente dans fstab
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    log_info "Swap désactivé — vérification :"
    free -h | grep -i swap

    # ── Étape 4 : Modules kernel + sysctl ────────────────────────────────────
    log_section "Étape 4/6 [COMMUN] Modules kernel et paramètres réseau"
    # doc : https://kubernetes.io/docs/setup/production-environment/container-runtimes/
    #       #forwarding-ipv4-and-letting-iptables-see-bridged-traffic

    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    # Charger les modules immédiatement sans attendre le reboot
    modprobe overlay
    modprobe br_netfilter

    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # Appliquer sans redémarrage
    sysctl --system -q
    log_info "Modules chargés : $(lsmod | grep -cE 'overlay|br_netfilter') / 2"

    # ── Étape 5 : Installation de containerd ─────────────────────────────────
    log_section "Étape 5/6 [COMMUN] Installation de containerd"
    # doc : https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd

    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    mkdir -p /etc/apt/keyrings
    # Ne re-télécharge la clé que si elle est absente (idempotent)
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y containerd.io

    # Générer la config par défaut puis activer SystemdCgroup
    # CRITIQUE : sans SystemdCgroup=true, kubelet crashe avec systemd comme cgroup driver
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

    # Vérification explicite — le script s'arrête si la modification a échoué
    if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
        log_error "Échec de l'activation de SystemdCgroup dans containerd"
        exit 1
    fi

    systemctl restart containerd
    systemctl enable containerd --quiet
    log_info "containerd $(containerd --version | awk '{print $3}') — statut : $(systemctl is-active containerd)"

    # ── Étape 6 : Installation de kubeadm + kubelet + kubectl ────────────────
    log_section "Étape 6/6 [COMMUN] Installation de kubeadm, kubelet, kubectl v${K8S_VERSION}"
    # doc : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

    apt-get install -y curl gpg

    mkdir -p -m 755 /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
            gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list

    apt-get update
    apt-get install -y kubelet kubeadm kubectl

    # Verrouiller les versions : empêche apt upgrade de casser le cluster
    apt-mark hold kubelet kubeadm kubectl

    log_info "Versions installées :"
    log_info "  kubeadm : $(kubeadm version -o short 2>/dev/null || kubeadm version)"
    log_info "  kubectl : $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    log_info "  kubelet : $(kubelet --version)"
}

# =============================================================================
#  PARTIE MASTER — exécutée UNIQUEMENT sur le controlplane
# =============================================================================
master_setup() {

    # ── Étape M1 : Init du cluster ────────────────────────────────────────────
    log_section "Étape M1 [MASTER] Initialisation du cluster Kubernetes ${K8S_EXACT_VERSION}"
    # doc : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
    #       create-cluster-kubeadm/#initializing-your-control-plane-node

    # Pré-pull des images pour un init plus rapide et une détection précoce des erreurs réseau
    log_info "Pré-téléchargement des images Kubernetes ${K8S_EXACT_VERSION}..."
    kubeadm config images pull --kubernetes-version="${K8S_EXACT_VERSION}" -q
    log_info "Images téléchargées"

    # Initialisation du cluster
    log_info "Lancement de kubeadm init (peut prendre 2-3 minutes)..."
    kubeadm init \
        --apiserver-advertise-address="${MASTER_IP}" \
        --pod-network-cidr="${POD_CIDR}" \
        --kubernetes-version="${K8S_EXACT_VERSION}" \
        --node-name=controlplane \
        --cri-socket=unix:///var/run/containerd/containerd.sock \
        2>&1 | tee /var/log/kubeadm-init.log

    log_info "kubeadm init terminé"

    # ── Étape M2 : Configuration kubectl ─────────────────────────────────────
    log_section "Étape M2 [MASTER] Configuration de kubectl"
    # Configuration pour root (utilisateur du script Vagrant)
    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config
    chmod 600 /root/.kube/config
    log_info "kubectl configuré pour root"

    # Configuration pour l'utilisateur vagrant (pour usage interactif lors de vagrant ssh)
    ## mkdir -p /home/vagrant/.kube
    ## cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
    ## chown -R vagrant:vagrant /home/vagrant/.kube
    ## chmod 600 /home/vagrant/.kube/config
    ## log_info "kubectl configuré pour vagrant"

    # On exporte KUBECONFIG pour la suite du script (session root)
    export KUBECONFIG=/etc/kubernetes/admin.conf

    # ── Étape M3 : Autocomplétion kubectl ────────────────────────────────────
    log_section "Étape M3 [MASTER] Autocomplétion kubectl et alias"

    # Installation de bash-completion si absent
    apt-get install -y bash-completion

    # Configuration pour root
    cat >> /root/.bashrc <<'BASHRC'

# ── Kubernetes ────────────────────────────────────
source /usr/share/bash-completion/bash_completion
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
# ─────────────────────────────────────────────────
BASHRC

    # Configuration pour vagrant
    cat >> /home/vagrant/.bashrc <<'BASHRC'

# ── Kubernetes ────────────────────────────────────
source /usr/share/bash-completion/bash_completion
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
# ─────────────────────────────────────────────────
BASHRC

    log_info "Autocomplétion et alias 'k' configurés pour root et vagrant"

    # ── Étape M4 : Génération et partage du join command ─────────────────────
    log_section "Étape M4 [MASTER] Génération de la commande kubeadm join"

    # Générer la commande join complète et la sauvegarder dans /vagrant
    # /vagrant est le dossier synchronisé automatiquement par VirtualBox
    # entre le dossier hôte (où se trouve le Vagrantfile) et chaque VM
    kubeadm token create --print-join-command > "${JOIN_FILE}"
    chmod +x "${JOIN_FILE}"

    log_info "Commande join générée et sauvegardée dans ${JOIN_FILE}"
    log_info "Contenu : $(cat ${JOIN_FILE})"

    # ── Étape M5 : Déploiement de Calico CNI ─────────────────────────────────
    log_section "Étape M5 [MASTER] Déploiement du CNI Calico ${CALICO_VERSION}"
    # doc : https://docs.tigera.io/calico/latest/getting-started/kubernetes/
    #       self-managed-onprem/onpremises

    # Installation de l'opérateur Tigera (gestionnaire du cycle de vie Calico)
    kubectl create -f \
        "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

    log_info "Opérateur Tigera déployé — attente de son démarrage (15s)..."
    sleep 15

    # Télécharger la config Calico et adapter le CIDR
    # IMPORTANT : le CIDR doit correspondre exactement à --pod-network-cidr de kubeadm init
    curl -fsSL \
        "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
        -o /tmp/calico-custom-resources.yaml

    # Remplacement du CIDR par défaut Calico (192.168.0.0/16) par notre CIDR (10.244.0.0/16)
    sed -i "s|192.168.0.0/16|${POD_CIDR}|g" /tmp/calico-custom-resources.yaml

    # Vérification du remplacement avant d'appliquer
    if ! grep -q "${POD_CIDR}" /tmp/calico-custom-resources.yaml; then
        log_error "Le remplacement du CIDR dans custom-resources.yaml a échoué"
        exit 1
    fi
    log_info "CIDR Calico configuré sur ${POD_CIDR}"

    kubectl create -f /tmp/calico-custom-resources.yaml

    # Attendre que tous les pods Calico soient Ready (max 3 minutes)
    log_info "Attente que Calico soit opérationnel (max 3 min)..."
    kubectl wait --for=condition=Ready pods \
        --all -n calico-system \
        --timeout=180s \
        || log_warn "Timeout Calico — certains pods ne sont pas encore prêts. Vérifier : kubectl get pods -n calico-system"

    # ── Étape M6 : Retrait de la taint du controlplane ───────────────────────
    log_section "Étape M6 [MASTER] Retrait de la taint NoSchedule du controlplane"
    # Par défaut, kubeadm pose node-role.kubernetes.io/control-plane:NoSchedule
    # ce qui empêche tout pod applicatif d'être schedulé sur le master.
    # En lab, on retire cette taint pour utiliser les deux nœuds.
    # En production, on la conserverait.
    kubectl taint nodes controlplane \
        node-role.kubernetes.io/control-plane:NoSchedule- \
        --overwrite 2>/dev/null || true

    log_info "Taint NoSchedule retirée — le controlplane peut maintenant accueillir des pods"

    # ── Étape M7 : Installation de Helm ──────────────────────────────────────
    log_section "Étape M7 [MASTER] Installation de Helm"
    # doc : https://helm.sh/docs/intro/install/

    if ! command -v helm &>/dev/null; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    else
        log_info "Helm déjà installé — version : $(helm version --short)"
    fi

    # Autocomplétion Helm pour root et vagrant
    cat >> /root/.bashrc <<'BASHRC'
source <(helm completion bash)
BASHRC
    cat >> /home/vagrant/.bashrc <<'BASHRC'
source <(helm completion bash)
BASHRC

    log_info "Helm $(helm version --short) installé"

    # # ── Étape M8 : Déploiement du Kubernetes Dashboard ───────────────────────
    # log_section "Étape M8 [MASTER] Déploiement du Kubernetes Dashboard"
    # # doc : https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/

    # helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/ --force-update -q
    # helm repo update -q

    # helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
    #     --create-namespace \
    #     --namespace kubernetes-dashboard \
    #     --wait \
    #     --timeout 3m \
    #     --atomic    # rollback automatique si l'install échoue

    # log_info "Dashboard déployé"
    # log_info "Services Dashboard :"
    # kubectl get svc -n kubernetes-dashboard

#     # ── Étape M9 : Création des utilisateurs RBAC Dashboard ──────────────────
#     log_section "Étape M9 [MASTER] Création des utilisateurs RBAC Dashboard"
#     # doc RBAC     : https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#     # doc sample   : https://github.com/kubernetes/dashboard/blob/master/docs/user/
#     #                access-control/creating-sample-user.md

#     # ── Utilisateur Admin (cluster-admin) ─────────────────────────────────────
#     kubectl apply -f - <<'EOF'
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: dashboard-admin
#   namespace: kubernetes-dashboard
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRoleBinding
# metadata:
#   name: dashboard-admin
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: ClusterRole
#   name: cluster-admin
# subjects:
# - kind: ServiceAccount
#   name: dashboard-admin
#   namespace: kubernetes-dashboard
# ---
# # Secret long-lived : génère un token permanent lié au ServiceAccount admin
# apiVersion: v1
# kind: Secret
# metadata:
#   name: dashboard-admin-secret
#   namespace: kubernetes-dashboard
#   annotations:
#     kubernetes.io/service-account.name: "dashboard-admin"
# type: kubernetes.io/service-account-token
# EOF

#     # ── Utilisateur Read-Only (viewonly) ──────────────────────────────────────
#     kubectl apply -f - <<'EOF'
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: dashboard-readonly
#   namespace: kubernetes-dashboard
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRole
# metadata:
#   name: dashboard-viewonly
# rules:
# - apiGroups: [""]
#   resources:
#   - configmaps
#   - endpoints
#   - persistentvolumeclaims
#   - pods
#   - pods/log
#   - pods/status
#   - replicationcontrollers
#   - serviceaccounts
#   - services
#   - nodes
#   - persistentvolumes
#   - namespaces
#   - events
#   - limitranges
#   - resourcequotas
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["apps"]
#   resources:
#   - daemonsets
#   - deployments
#   - replicasets
#   - statefulsets
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["autoscaling"]
#   resources: ["horizontalpodautoscalers"]
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["batch"]
#   resources: ["cronjobs", "jobs"]
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["networking.k8s.io"]
#   resources: ["ingresses", "networkpolicies"]
#   verbs: ["get", "list", "watch"]
# - apiGroups: ["storage.k8s.io"]
#   resources: ["storageclasses"]
#   verbs: ["get", "list", "watch"]
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRoleBinding
# metadata:
#   name: dashboard-readonly
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: ClusterRole
#   name: dashboard-viewonly
# subjects:
# - kind: ServiceAccount
#   name: dashboard-readonly
#   namespace: kubernetes-dashboard
# ---
# # Secret long-lived : génère un token permanent lié au ServiceAccount read-only
# apiVersion: v1
# kind: Secret
# metadata:
#   name: dashboard-readonly-secret
#   namespace: kubernetes-dashboard
#   annotations:
#     kubernetes.io/service-account.name: "dashboard-readonly"
# type: kubernetes.io/service-account-token
# EOF

#     log_info "Utilisateurs RBAC créés (admin + read-only)"

#     # ── Résumé final ──────────────────────────────────────────────────────────
#     log_section "✅ CLUSTER PRÊT"

#     echo ""
#     log_info "État des nœuds :"
#     kubectl get nodes -o wide

#     echo ""
#     log_info "Pods système :"
#     kubectl get pods --all-namespaces | grep -v "Running\|Completed" \
#         && log_warn "Certains pods ne sont pas encore Running" \
#         || log_info "Tous les pods sont Running ou Completed"

#     echo ""
#     log_info "══════════════════════════════════════════════════"
#     log_info " ACCÈS AU DASHBOARD"
#     log_info "══════════════════════════════════════════════════"
#     log_info " Depuis le controlplane, lancer :"
#     log_info "   kubectl port-forward svc/kubernetes-dashboard-kong-proxy \\"
#     log_info "     -n kubernetes-dashboard 8443:443 --address=0.0.0.0 &"
#     log_info ""
#     log_info " Puis ouvrir dans le navigateur de la machine hôte :"
#     log_info "   https://192.168.90.10:8443"
#     log_info "══════════════════════════════════════════════════"

#     echo ""
#     log_info "TOKEN ADMIN (copier pour se connecter au Dashboard) :"
#     echo "──────────────────────────────────────────────────"
#     kubectl get secret dashboard-admin-secret \
#         -n kubernetes-dashboard \
#         -o jsonpath="{.data.token}" | base64 --decode
#     echo ""
#     echo "──────────────────────────────────────────────────"

#     echo ""
#     log_info "TOKEN READ-ONLY (copier pour se connecter au Dashboard) :"
#     echo "──────────────────────────────────────────────────"
#     kubectl get secret dashboard-readonly-secret \
#         -n kubernetes-dashboard \
#         -o jsonpath="{.data.token}" | base64 --decode
#     echo ""
#     echo "──────────────────────────────────────────────────"
# }

# =============================================================================
#  PARTIE WORKER — exécutée UNIQUEMENT sur les nœuds worker
# =============================================================================
worker_setup() {

    log_section "Étape W1 [WORKER] Jonction au cluster Kubernetes"
    # doc : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
    #       create-cluster-kubeadm/#join-nodes

    # Attendre que le controlplane ait généré le fichier join
    # Le controlplane doit être provisionné avant les workers (garanti par l'ordre
    # de définition dans le Vagrantfile)
    local elapsed=0
    log_info "Attente du fichier join généré par le controlplane (max ${JOIN_TIMEOUT}s)..."

    while [ ! -f "${JOIN_FILE}" ]; do
        sleep 5
        elapsed=$((elapsed + 5))

        if [ $elapsed -ge ${JOIN_TIMEOUT} ]; then
            log_error "Timeout (${JOIN_TIMEOUT}s) : ${JOIN_FILE} introuvable."
            log_error "Causes possibles :"
            log_error "  - Le controlplane n'a pas encore terminé son init"
            log_error "  - Le dossier /vagrant n'est pas monté (vérifier VirtualBox Guest Additions)"
            log_error "  - kubeadm init a échoué sur le controlplane (voir /var/log/kubeadm-init.log)"
            log_error ""
            log_error "Pour rejouer manuellement :"
            log_error "  vagrant ssh controlplane -- sudo kubeadm token create --print-join-command"
            log_error "  puis copier la commande et l'exécuter sur ce nœud"
            exit 1
        fi

        # Afficher la progression toutes les 30 secondes
        if [ $((elapsed % 30)) -eq 0 ]; then
            log_info "  Toujours en attente... (${elapsed}s / ${JOIN_TIMEOUT}s)"
        fi
    done

    log_info "Fichier join trouvé après ${elapsed}s"

    # Exécuter la commande join en ajoutant le node-name et le cri-socket
    # Le fichier join_command.sh contient déjà : kubeadm join <ip>:6443 --token ... --discovery-token-ca-cert-hash ...
    log_info "Jonction au cluster en cours..."
    bash "${JOIN_FILE}" \
        --node-name="${HOSTNAME}" \
        --cri-socket=unix:///var/run/containerd/containerd.sock

    log_info "✅ ${HOSTNAME} a rejoint le cluster avec succès"
    log_info "Vérifier depuis le controlplane : kubectl get nodes"
}

# =============================================================================
#  POINT D'ENTRÉE — détection du rôle via le hostname
# =============================================================================

log_section "Démarrage du script install_kubernetes.sh"
log_info "Nœud    : $(hostname)"
log_info "IP      : $(hostname -I | awk '{print $2}')"
log_info "K8s     : ${K8S_EXACT_VERSION}"
log_info "Calico  : ${CALICO_VERSION}"
log_info "Pod CIDR: ${POD_CIDR}"
echo ""

# ── Partie commune (tous les nœuds) ──────────────────────────────────────────
common_setup

# ── Branchement selon le rôle ─────────────────────────────────────────────────
case "$HOSTNAME" in

    controlplane)
        log_info "Rôle détecté : ★ CONTROL PLANE"
        master_setup
        ;;

    node*)
        log_info "Rôle détecté : ◆ WORKER NODE"
        worker_setup
        ;;

    *)
        log_error "Hostname '${HOSTNAME}' non reconnu."
        log_error "Hostnames attendus : 'controlplane' ou 'node<N>' (ex: node1, node2...)"
        log_error "Vérifier la configuration 'vm.hostname' dans le Vagrantfile."
        exit 1
        ;;
esac

log_section "🎉 Script terminé sur $(hostname)"
