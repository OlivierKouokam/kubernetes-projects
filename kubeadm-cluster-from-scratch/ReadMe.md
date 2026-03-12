# 🚀 Déploiement d'un Cluster Kubernetes 1.34 avec KubeAdm

> **Environnement** : 1 Master (controlplane) + 1 Worker (node1) sur Ubuntu 22.04  
> **Outils** : Vagrant + VirtualBox, kubeadm, containerd, Calico CNI, Helm, Kubernetes Dashboard  
> **Version Kubernetes** : 1.34.x

---

## 📋 Table des Matières

1. [Architecture et prérequis](#1-architecture-et-prérequis)
2. [Provisionnement des VMs avec Vagrant](#2-provisionnement-des-vms-avec-vagrant)
3. [Préparation de tous les nœuds (controlplane + worker)](#3-préparation-de-tous-les-nœuds-controlplane--worker)
4. [Installation des composants Kubernetes](#4-installation-des-composants-kubernetes)
5. [Initialisation du cluster (Master uniquement)](#5-initialisation-du-cluster-master-uniquement)
6. [Jonction du Worker au cluster](#6-jonction-du-worker-au-cluster)
7. [Déploiement du plugin CNI : Calico](#7-déploiement-du-plugin-cni--calico)
8. [Test du cluster : Application Guestbook](#8-test-du-cluster--application-guestbook)
9. [Installation de Helm](#9-installation-de-helm)
10. [Déploiement du Kubernetes Dashboard](#10-déploiement-du-kubernetes-dashboard)
11. [Création des utilisateurs Dashboard (read-only et admin)](#11-création-des-utilisateurs-dashboard-read-only-et-admin)
12. [Accès au Dashboard via port-forward](#12-accès-au-dashboard-via-port-forward)

---

## 1. Architecture et prérequis

### Topologie du cluster

| Rôle          | Hostname      | IP             | CPU | RAM  |
|---------------|---------------|----------------|-----|------|
| Control Plane | controlplane  | 192.168.90.10  | 2   | 4 Go |
| Worker Node   | node1         | 192.168.90.11  | 2   | 3 Go |

### Réseaux Kubernetes

| Réseau        | CIDR            | Usage                                    |
|---------------|-----------------|------------------------------------------|
| Nœuds (VMs)  | 192.168.90.0/24 | Réseau hôte Vagrant (existant)           |
| Pods (Calico) | 10.244.0.0/16   | IPs attribuées aux pods                  |
| Services      | 10.96.0.0/12    | IPs virtuelles des services (défaut K8s) |

> ⚠️ **Pourquoi `10.244.0.0/16` pour les pods et pas `192.168.0.0/16` ?**  
> Le réseau des VMs est `192.168.90.0/24`. Or `192.168.0.0/16` englobe **toute** la plage `192.168.x.x`,
> ce qui inclut tes nœuds. Kubernetes routerait alors le trafic vers tes VMs via le réseau pod
> au lieu de l'interface physique → pannes réseau imprévisibles.  
> `10.244.0.0/16` est entièrement distinct : aucun chevauchement possible.

### Prérequis sur la machine hôte

- [VirtualBox](https://www.virtualbox.org/) ≥ 6.1 installé
- [Vagrant](https://www.vagrantup.com/) ≥ 2.3 installé
- Au moins 8 Go de RAM disponible sur l'hôte
- Connexion Internet (pour le pull des images)

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#before-you-begin

---

## 2. Provisionnement des VMs avec Vagrant

### Vagrantfile

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :
Vagrant.configure("2") do |config|
    config.vm.define "controlplane" do |controlplane|
      controlplane.vm.box = "eazytraining/ubuntu2204"
      controlplane.vm.box_version = "1.0"
      controlplane.vm.network "private_network", type: "static", ip: "192.168.90.10"
      controlplane.vm.hostname = "controlplane"
      controlplane.vm.provider "virtualbox" do |v|
        v.name = "controlplane"
        v.memory = 4096
        v.cpus = 2
      end
    end
    nodes=1
    ram_node=3072
    cpu_node=2
    (1..nodes).each do |i|
      config.vm.define "node#{i}" do |node|
        node.vm.box = "eazytraining/ubuntu2204"
        node.vm.box_version = "1.0"
        node.vm.network "private_network", type: "static", ip: "192.168.90.1#{i}"
        node.vm.hostname = "node#{i}"
        node.vm.provider "virtualbox" do |v|
          v.name = "node#{i}"
          v.memory = ram_node
          v.cpus = cpu_node
        end
      end
    end
  end
```

### Démarrage des VMs

```powershell
# Dans le dossier contenant le Vagrantfile
vagrant up

# Vérification que les VMs sont actives
vagrant status
```

### Connexion aux VMs

```powershell
# Se connecter au master
vagrant ssh controlplane

# Se connecter au worker (depuis un autre terminal)
vagrant ssh node1
```

### Gestion des SnapShots 

```powershell
### Installation du plugin pour les Snapshots
vagrant plugin install vagrant-vbguest
```

```powershell
# Save/Susprendre les VMs
vagrant suspend

# Prendre un snapshot
vagrant snapshot save <snapshot_name>

# lister les snapshots
vagrant snapshot list

# Restorer un snapshot
vagrant snapshot restore <snapshot_name>

# Relancer les VMs
vagrant resume
```

---

## 3. Préparation de tous les nœuds (controlplane + worker)

> ⚠️ **Les commandes de cette section doivent être exécutées sur TOUS les nœuds** (controlplane ET node1).

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl

### 3.1 Mise à jour du système

```bash
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update && sudo apt-get upgrade -y
```

### 3.2 Configuration du fichier /etc/hosts

Ajouter les entrées sur chaque nœud pour la résolution DNS locale :

```bash
sudo tee -a /etc/hosts <<EOF
192.168.90.10 controlplane
192.168.90.11 node1
EOF
```

### 3.3 Désactivation du swap

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#before-you-begin
>
> Kubernetes exige que le swap soit désactivé. Sans cette étape, `kubeadm init` échouera.

```bash
# Désactivation immédiate
sudo swapoff -a

# Désactivation permanente (commenter la ligne swap dans fstab)
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Vérification : la colonne Swap doit afficher 0B
free -h
```

### 3.4 Activation des modules kernel nécessaires

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/container-runtimes/#forwarding-ipv4-and-letting-iptables-see-bridged-traffic

```bash
# Chargement des modules au démarrage
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Activation immédiate des modules
sudo modprobe overlay
sudo modprobe br_netfilter

# Configuration des paramètres sysctl (networking)
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Application des paramètres sans redémarrage
sudo sysctl --system

# Vérification
lsmod | grep br_netfilter
lsmod | grep overlay
```

### 3.5 Installation du container runtime : containerd

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd

```bash
export DEBIAN_FRONTEND=noninteractive
# Installation des dépendances
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Ajout du repository Docker (contient containerd)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

# Installation de containerd
sudo apt-get install -y containerd.io

# Génération de la configuration par défaut
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# IMPORTANT : Activer SystemdCgroup = true (requis par Kubernetes avec systemd)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Vérification de la modification
grep 'SystemdCgroup' /etc/containerd/config.toml
# Doit afficher : SystemdCgroup = true

# Redémarrage et activation de containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# Vérification du statut
sudo systemctl status containerd
```
### 3.6 Installation du client nfs-common

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
```

---

## 4. Installation des composants Kubernetes

> ⚠️ **Les commandes de cette section doivent être exécutées sur TOUS les nœuds** (controlplane ET node1).

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl

```bash
# Installation des dépendances
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Création du dossier keyrings s'il n'existe pas
sudo mkdir -p -m 755 /etc/apt/keyrings

# Ajout de la clé GPG du repository Kubernetes 1.34
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Ajout du repository Kubernetes 1.34
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# Mise à jour et installation des trois composants
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

# Verrouillage des versions pour éviter les mises à jour automatiques non souhaitées
sudo apt-mark hold kubelet kubeadm kubectl

# Vérification des versions installées
kubeadm version
kubectl version --client
kubelet --version
```

---

## 5. Initialisation du cluster (Master uniquement)

> ⚠️ **Les commandes de cette section doivent être exécutées UNIQUEMENT sur le controlplane.**

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#initializing-your-control-plane-node

### 5.1 Pré-pull des images (optionnel mais recommandé)

```bash
# Vérifier quelles images seront téléchargées
sudo kubeadm config images list --kubernetes-version=v1.34.0

# Pré-téléchargement des images (accélère l'init et détecte les erreurs réseau tôt)
sudo kubeadm config images pull --kubernetes-version=v1.34.0
```

### 5.2 Initialisation du cluster

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.90.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version=v1.34.0 \
  --node-name=controlplane \
  --cri-socket=unix:///var/run/containerd/containerd.sock
```

> 💡 **Important** : À la fin de l'init, kubeadm affiche la commande `kubeadm join`.
> **Copiez et conservez cette commande** — elle sera utilisée à l'étape 6.
>
> Elle ressemble à ceci :
> ```
> kubeadm join 192.168.90.10:6443 --token <TOKEN> \
>   --discovery-token-ca-cert-hash sha256:<HASH>
> ```

### 5.3 Configuration de kubectl pour l'utilisateur courant

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Vérification : le master apparaît en "NotReady" (normal, le CNI n'est pas encore installé)
kubectl get nodes
kubectl get pods -n kube-system
```

### 5.4 Configuration de l'auto-complétion
Installer bash-completion
```bash
sudo apt update
sudo apt install -y bash-completion
```

Activer bash-completion dans ta session
```bash
echo 'source /usr/share/bash-completion/bash_completion' >> ~/.bashrc
source ~/.bashrc
```

Activer l’auto-complétion pour kubectl
```bash
echo 'source <(kubectl completion bash)' >> ~/.bashrc
source ~/.bashrc
```

(Optionnel mais recommandé) Alias k + auto-complétion
```bash
echo "alias k=kubectl" >> ~/.bashrc
echo "complete -o default -F __start_kubectl k" >> ~/.bashrc
source ~/.bashrc
```
---

## 6. Jonction du Worker au cluster

> ⚠️ **Les commandes de cette section doivent être exécutées UNIQUEMENT sur node1.**

> 📖 **Doc officielle** : https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#join-nodes

```bash
# Exécuter la commande kubeadm join copiée lors de l'étape 5.2
# Exemple (vos valeurs de token et hash seront différentes) :
sudo kubeadm join 192.168.90.10:6443 \
  --token <VOTRE_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<VOTRE_HASH> \
  --node-name=node1 \
  --cri-socket=unix:///var/run/containerd/containerd.sock
```

### Si le token a expiré (valable 24h par défaut)

```bash
# Générer un nouveau token depuis le controlplane, avec la commande join complète
sudo kubeadm token create --print-join-command
```

### Vérification depuis le controlplane

```bash
# Les nœuds sont en "NotReady" jusqu'à l'installation du CNI — c'est normal
kubectl get nodes
```

---

## 7. Déploiement du plugin CNI : Calico

> ⚠️ **Les commandes de cette section doivent être exécutées UNIQUEMENT sur le controlplane.**

> 📖 **Doc officielle Kubernetes (addons)** : https://kubernetes.io/docs/concepts/cluster-administration/addons/#networking-and-network-policy  
> 📖 **Doc officielle Calico** : https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises

### Pourquoi Calico ?

Calico est la solution CNI la plus utilisée en production. Elle offre des network policies avancées (pare-feu entre pods), de bonnes performances et une compatibilité totale avec kubeadm.

### Installation via l'opérateur Tigera

```bash
# Étape 1 : Installer l'opérateur Tigera et ses CRDs
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml

# Vérification de l'opérateur
kubectl get pods -n tigera-operator

# Étape 2 : Télécharger le fichier de configuration pour l'adapter
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/custom-resources.yaml
```

### Adaptation du CIDR

Le fichier `custom-resources.yaml` contient par défaut `192.168.0.0/16`.
Il faut le remplacer par `10.244.0.0/16` pour correspondre exactement à ce qui a été passé à `kubeadm init` :

```bash
# Remplacer le CIDR Calico par défaut par notre CIDR
sed -i 's|192.168.0.0/16|10.244.0.0/16|g' custom-resources.yaml

# Vérification
grep 'cidr' custom-resources.yaml
# Doit afficher : cidr: 10.244.0.0/16

# Appliquer la configuration
kubectl create -f custom-resources.yaml

# Suivre le démarrage des pods Calico (attendre que tous soient en Running)
watch kubectl get pods -n calico-system
```
### Autoriser le controlplane à recevoir des pods normaux

```bash
kubectl taint nodes controlplane node-role.kubernetes.io/control-plane:NoSchedule-
```

### Vérification finale du cluster

```bash
# Tous les nœuds doivent désormais être en état "Ready"
kubectl get nodes -o wide

# Tous les pods système doivent être en Running
kubectl get pods -n kube-system
kubectl get pods -n calico-system
```

---

## 8. Test du cluster : Application Guestbook

> 📖 **Doc officielle** : https://kubernetes.io/docs/tutorials/stateless-application/guestbook/

L'application Guestbook est l'exemple officiel Kubernetes. Elle illustre une architecture multi-tier :
un backend Redis (1 leader + 2 followers) et un frontend PHP (3 replicas) exposé via NodePort.

### 8.1 Déploiement du backend Redis Leader

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-leader
  labels:
    app: redis
    role: leader
    tier: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
        role: leader
        tier: backend
    spec:
      containers:
      - name: leader
        image: docker.io/redis:6.0.5
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
        ports:
        - containerPort: 6379
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis-leader
  labels:
    app: redis
    role: leader
    tier: backend
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: redis
    role: leader
    tier: backend
EOF
```

### 8.2 Déploiement des Redis Followers

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-follower
  labels:
    app: redis
    role: follower
    tier: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
        role: follower
        tier: backend
    spec:
      containers:
      - name: follower
        image: gcr.io/google_samples/gb-redis-follower:v2
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
        ports:
        - containerPort: 6379
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis-follower
  labels:
    app: redis
    role: follower
    tier: backend
spec:
  ports:
  - port: 6379
  selector:
    app: redis
    role: follower
    tier: backend
EOF
```

### 8.3 Déploiement du Frontend PHP

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: guestbook
    tier: frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: guestbook
      tier: frontend
  template:
    metadata:
      labels:
        app: guestbook
        tier: frontend
    spec:
      containers:
      - name: php-redis
        image: gcr.io/google_samples/gb-frontend:v5
        env:
        - name: GET_HOSTS_FROM
          value: dns
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
        ports:
        - containerPort: 80
EOF

# Service NodePort pour accéder à l'app depuis la machine hôte
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: frontend
  labels:
    app: guestbook
    tier: frontend
spec:
  type: NodePort
  ports:
  - port: 80
    nodePort: 30007
  selector:
    app: guestbook
    tier: frontend
EOF
```

### 8.4 Vérification du déploiement

```bash
# Vérifier que tous les pods sont Running et bien distribués sur les nœuds
kubectl get pods -o wide

# Vérifier les services
kubectl get services

# Accéder à l'application depuis la machine hôte
# http://192.168.90.10:30007  (via le master)
# http://192.168.90.11:30007  (via le worker)
```

### 8.5 Test du scaling

```bash
# Scale le frontend de 3 à 5 replicas
kubectl scale deployment frontend --replicas=5

# Observer la distribution des nouveaux pods sur les deux nœuds
kubectl get pods -o wide | grep frontend

# Revenir à 3 replicas
kubectl scale deployment frontend --replicas=3
```

### 8.6 Test de la communication réseau inter-pods

```bash
# Lancer un pod de debug temporaire pour tester la résolution DNS et la connectivité
kubectl run test-net --image=busybox --rm -it --restart=Never -- sh

# Dans le pod (depuis le réseau pod 10.244.x.x) :
nslookup redis-leader      # résolution DNS du service Redis Leader
nslookup frontend          # résolution DNS du service frontend
wget -q -O- frontend       # requête HTTP vers le frontend PHP
exit
```

### 8.7 Nettoyage de l'application de test

```bash
kubectl delete deployment frontend redis-leader redis-follower
kubectl delete service frontend redis-leader redis-follower
```
```bash
kubectl delete -f https://k8s.io/examples/application/guestbook/redis-leader-deployment.yaml
kubectl delete -f https://k8s.io/examples/application/guestbook/redis-leader-service.yaml
kubectl delete -f https://k8s.io/examples/application/guestbook/redis-follower-deployment.yaml
kubectl delete -f https://k8s.io/examples/application/guestbook/redis-follower-service.yaml
kubectl delete -f https://k8s.io/examples/application/guestbook/frontend-deployment.yaml
kubectl delete -f https://k8s.io/examples/application/guestbook/frontend-service.yaml
```

---

## 9. Installation de Helm

> 📖 **Doc officielle Helm** : https://helm.sh/docs/intro/install/

Helm est le gestionnaire de packages pour Kubernetes. Il simplifie l'installation d'applications complexes comme le Dashboard Kubernetes.

```bash
# Sur le controlplane — installation via le script officiel
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Vérification
helm version

# Autocomplétion bash (optionnel mais pratique)
echo 'source <(helm completion bash)' >> ~/.bashrc
source ~/.bashrc
```

---

## 10. Déploiement du Kubernetes Dashboard

> 📖 **Doc officielle** : https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/  
> 📖 **ArtifactHub chart** : https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard

### 10.1 Installation via kubectl

```bash
# Appliquer le manifest officiel
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
```

### 10.2 Installation via Helm

```bash
# Ajout du repository Helm pour le Dashboard
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm repo update

# Installation dans son namespace dédié
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --create-namespace \
  --namespace kubernetes-dashboard

# Attendre que tous les pods soient en Running
kubectl get pods -n kubernetes-dashboard --watch

# Vérifier les services créés — noter le nom exact du service proxy
kubectl get svc -n kubernetes-dashboard
```

> 💡 Le chart v7+ embarque Kong comme proxy par défaut. Le service exposant le Dashboard
> s'appelle généralement `kubernetes-dashboard-kong-proxy` sur le port 443.
> Vérifier avec `kubectl get svc -n kubernetes-dashboard` avant l'étape 12.

---

## 11. Création des utilisateurs Dashboard (read-only et admin)

> 📖 **Doc officielle RBAC** : https://kubernetes.io/docs/reference/access-authn-authz/rbac/  
> 📖 **Création d'un sample user** : https://github.com/kubernetes/dashboard/blob/master/docs/user/access-control/creating-sample-user.md

### 11.1 Utilisateur Admin (lecture + écriture complète)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: dashboard-admin
  namespace: kubernetes-dashboard
---
# Secret long-lived : génère un token permanent associé au ServiceAccount
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-admin-secret
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: "dashboard-admin"
type: kubernetes.io/service-account-token
EOF
```

### 11.2 Utilisateur Read-Only (visualisation uniquement)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-readonly
  namespace: kubernetes-dashboard
---
# ClusterRole personnalisé : uniquement get/list/watch sur les ressources essentielles
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dashboard-viewonly
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - endpoints
  - persistentvolumeclaims
  - pods
  - pods/log
  - pods/status
  - replicationcontrollers
  - serviceaccounts
  - services
  - nodes
  - persistentvolumes
  - namespaces
  - events
  - limitranges
  - resourcequotas
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources:
  - daemonsets
  - deployments
  - replicasets
  - statefulsets
  verbs: ["get", "list", "watch"]
- apiGroups: ["autoscaling"]
  resources:
  - horizontalpodautoscalers
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources:
  - cronjobs
  - jobs
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources:
  - ingresses
  - networkpolicies
  verbs: ["get", "list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources:
  - storageclasses
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dashboard-viewonly
subjects:
- kind: ServiceAccount
  name: dashboard-readonly
  namespace: kubernetes-dashboard
---
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-readonly-secret
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: "dashboard-readonly"
type: kubernetes.io/service-account-token
EOF
```

---

## 12. Accès au Dashboard via port-forward

> 📖 **Doc officielle port-forward** : https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/

Le `kubectl port-forward` crée un tunnel direct entre la machine qui exécute kubectl et le service cible dans le cluster. C'est la méthode la plus simple pour un lab local : aucun LoadBalancer, aucun Ingress Controller requis.

### 12.1 Récupération des tokens

```bash
# Token Admin (accès complet read-write)
echo "=== TOKEN ADMIN ==="
kubectl get secret dashboard-admin-secret \
  -n kubernetes-dashboard \
  -o jsonpath="{.data.token}" | base64 --decode
echo -e "\n"

# Token Read-Only (accès en lecture seule)
echo "=== TOKEN READ-ONLY ==="
kubectl get secret dashboard-readonly-secret \
  -n kubernetes-dashboard \
  -o jsonpath="{.data.token}" | base64 --decode
echo -e "\n"
```

### 12.2 Lancer le port-forward

```bash
# Vérifier d'abord le nom exact du service (peut varier selon la version du chart)
kubectl get svc -n kubernetes-dashboard

# Lancer le port-forward vers le service proxy du Dashboard
# --address=0.0.0.0 permet l'accès depuis la machine hôte quand kubectl
# est exécuté depuis l'intérieur d'une VM
kubectl port-forward svc/kubernetes-dashboard-kong-proxy \
  -n kubernetes-dashboard \
  8443:443 \
  --address=0.0.0.0
```

> 💡 Laisser ce terminal ouvert pendant toute la session Dashboard.
> Le tunnel se ferme dès que la commande est interrompue (Ctrl+C).

### 12.3 Accéder au Dashboard depuis le navigateur

Depuis la **machine hôte** (port-forward lancé dans la VM controlplane) :
```
https://192.168.90.10:8443
```

Si kubectl est installé **directement sur la machine hôte** :
```
https://localhost:8443
```

Ensuite :
1. Accepter l'avertissement de certificat auto-signé ("Avancé" → "Continuer")
2. Sélectionner **"Token"** comme méthode d'authentification
3. Coller le token souhaité (admin ou read-only) et cliquer **"Sign In"**

### 12.4 Comparaison des deux profils utilisateurs

| Action | Admin | Read-Only |
|--------|-------|-----------|
| Voir pods, deployments, services | ✅ | ✅ |
| Voir les logs des pods | ✅ | ✅ |
| Voir les namespaces et events | ✅ | ✅ |
| Créer / modifier des ressources | ✅ | ❌ |
| Supprimer des ressources | ✅ | ❌ |
| Scaler des deployments | ✅ | ❌ |
| Gérer les secrets | ✅ | ❌ |

### 12.5 Tokens temporaires (alternative pour les démos)

```bash
# Token admin valable 24h (expire automatiquement, plus sécurisé)
kubectl create token dashboard-admin \
  -n kubernetes-dashboard --duration=24h

# Token read-only valable 1h
kubectl create token dashboard-readonly \
  -n kubernetes-dashboard --duration=1h
```

---

## 🔧 Commandes utiles

```bash
# Statut général du cluster
kubectl get nodes -o wide
kubectl get pods --all-namespaces
kubectl cluster-info

# Vérifier les événements (debug)
kubectl get events --sort-by=.metadata.creationTimestamp

# Logs d'un pod
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous   # logs du crash précédent

# Décrire un nœud (ressources, events, pods planifiés)
kubectl describe node controlplane
kubectl describe node node1

# Redémarrer un déploiement proprement
kubectl rollout restart deployment/<nom>

# Afficher la configuration kubeadm du cluster
kubectl -n kube-system get configmap kubeadm-config -o yaml
```

---

## ⚠️ Troubleshooting

### Un nœud reste en "NotReady"

```bash
# Vérifier les logs du kubelet
sudo journalctl -u kubelet -f --no-pager | tail -50

# Vérifier les pods CNI Calico
kubectl get pods -n calico-system
kubectl describe pod <pod-calico> -n calico-system
```

### Erreur lors du kubeadm init

```bash
# Réinitialiser complètement et recommencer
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F
sudo ipvsadm --clear 2>/dev/null || true
```

### Token kubeadm join expiré

```bash
# Générer un nouveau token avec la commande join complète depuis le controlplane
sudo kubeadm token create --print-join-command
```

### Le port-forward se coupe

```bash
# Le port-forward n'est pas persistant — relancer simplement la commande.
# Pour le garder actif en arrière-plan :
kubectl port-forward svc/kubernetes-dashboard-kong-proxy \
  -n kubernetes-dashboard 8443:443 --address=0.0.0.0 &

# Pour l'arrêter :
kill %1
```

### Calico pods en "Init" ou "CrashLoopBackOff"

```bash
# Vérifier que le CIDR dans la configuration Calico correspond à kubeadm init
kubectl get installation default -o jsonpath='{.spec.calicoNetwork.ipPools[0].cidr}'
# Doit afficher : 10.244.0.0/16

# Vérifier les logs du pod calico-node
kubectl logs -n calico-system \
  $(kubectl get pod -n calico-system -l k8s-app=calico-node -o name | head -1)
```

---

## 📚 Références

| Sujet | Lien |
|-------|------|
| Prérequis kubeadm | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ |
| Créer un cluster kubeadm | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ |
| Container runtimes (containerd) | https://kubernetes.io/docs/setup/production-environment/container-runtimes/ |
| Calico CNI | https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises |
| App Guestbook (officielle) | https://kubernetes.io/docs/tutorials/stateless-application/guestbook/ |
| RBAC | https://kubernetes.io/docs/reference/access-authn-authz/rbac/ |
| port-forward | https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/ |
| Helm installation | https://helm.sh/docs/intro/install/ |
| Kubernetes Dashboard | https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/ |
| Dashboard sample user | https://github.com/kubernetes/dashboard/blob/master/docs/user/access-control/creating-sample-user.md |

---

*Rédigé pour Kubernetes v1.34 sur Ubuntu 22.04 — Février 2026*
