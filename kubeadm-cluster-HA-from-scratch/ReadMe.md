# 🚀 Déploiement d'un Cluster Kubernetes HA avec kubeadm
### 3 Masters + 2 Workers — Kubernetes v1.34

> 🎬 **Guide conçu pour une démonstration YouTube pas-à-pas**  
> Chaque section indique la page de documentation officielle Kubernetes utilisée.

---

## 🏗️ Architecture & Choix techniques

### Topologie : Stacked etcd

```
                    ┌──────────────────────────────┐
                    │   VIP : 192.168.1.100:6443   │  ← Point d'entrée unique
                    │   (Keepalived + HAProxy)      │    pour kubectl & les workers
                    │   hébergé sur les 3 masters   │
                    └──────────┬───────────────────┘
                               │ load balancing
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
   ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
   │    master-1      │ │    master-2      │ │    master-3      │
   │  192.168.1.10    │ │  192.168.1.11    │ │  192.168.1.12    │
   │  4 Go RAM        │ │  4 Go RAM        │ │  4 Go RAM        │
   │  ─────────────   │ │  ─────────────   │ │  ─────────────   │
   │  kube-apiserver  │ │  kube-apiserver  │ │  kube-apiserver  │
   │  etcd (leader?)  │ │  etcd (follower) │ │  etcd (follower) │
   │  controller-mgr  │ │  controller-mgr  │ │  controller-mgr  │
   │  scheduler       │ │  scheduler       │ │  scheduler       │
   │  HAProxy         │ │  HAProxy         │ │  HAProxy         │
   │  Keepalived★     │ │  Keepalived      │ │  Keepalived      │
   └─────────────────┘ └─────────────────┘ └─────────────────┘
              ★ = détient la VIP en temps normal

              ┌──────────────────────────────────────┐
              ▼                                      ▼
   ┌─────────────────┐                   ┌─────────────────┐
   │    worker-1      │                   │    worker-2      │
   │  192.168.1.20    │                   │  192.168.1.21    │
   │  3 Go RAM        │                   │  3 Go RAM        │
   │  ─────────────   │                   │  ─────────────   │
   │  kubelet         │                   │  kubelet         │
   │  containerd      │                   │  containerd      │
   │  Pods applicatifs│                   │  Pods applicatifs│
   └─────────────────┘                   └─────────────────┘
```

### 🤔 Pourquoi une VIP ? Pourquoi sur les masters ?

**Le problème sans VIP :** si tu configures `kubectl` et les workers pour pointer sur `master-1:6443`,
et que master-1 tombe, plus rien ne fonctionne — même si master-2 et master-3 sont parfaitement opérationnels.

**La solution — VIP avec Keepalived :**
La VIP `192.168.1.100` est une IP flottante qui "vit" toujours sur l'un des 3 masters.
Keepalived surveille HAProxy et bascule la VIP automatiquement en quelques secondes si le master actif tombe.
`kubectl` et les workers ne voient qu'une seule IP stable : `192.168.1.100:6443`.

**Pourquoi sur les masters et pas une VM dédiée ?**
En production on utilise souvent un LB externe (cloud LB, F5, Nginx dédié...). Ici, pour ce lab,
on colle HAProxy + Keepalived directement sur les 3 masters. C'est la topologie recommandée par la
documentation officielle K8s pour les environnements sans infrastructure LB externe. On économise une VM.

### 🤔 Les 3 masters traitent-ils tous les requêtes ?

Oui, avec des nuances :

- **API Server** : les 3 tournent, HAProxy distribue les requêtes en round-robin sur les 3.
- **etcd** : un seul leader écrit (élu par RAFT), les 2 autres répliquent. En cas de perte d'un master, les 2 restants élisent un nouveau leader automatiquement. Le cluster tolère la perte de 1 master sur 3 (quorum = 2).
- **controller-manager & scheduler** : un seul actif à la fois (leader election K8s), les autres sont en standby.
- **Workers** : n'exécutent que les pods applicatifs, zéro composant control-plane.

---

## 📋 Inventaire

| Rôle     | Hostname | IP           | RAM  | CPU |
|----------|----------|--------------|------|-----|
| Master 1 | master-1 | 192.168.1.10 | 4 Go | 1   |
| Master 2 | master-2 | 192.168.1.11 | 4 Go | 1   |
| Master 3 | master-3 | 192.168.1.12 | 4 Go | 1   |
| Worker 1 | worker-1 | 192.168.1.20 | 3 Go | 1   |
| Worker 2 | worker-2 | 192.168.1.21 | 3 Go | 1   |
| VIP LB   | —        | 192.168.1.100| —    | —   |

> **OS :** Ubuntu 22.04 LTS  
> **Container runtime :** containerd  
> **CNI :** Calico — podSubnet `10.244.0.0/16`  
> ⚠️ On évite `192.168.0.0/16` pour ne pas entrer en conflit avec le réseau des VMs

---

## PHASE 1 — Pré-requis système (Tous les nœuds)

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#before-you-begin

### 1.1 — Hostnames et résolution DNS locale

Sur **chaque nœud**, adapter le hostname :

```bash
# Exemple sur master-1 — répéter sur chaque machine avec son nom
sudo hostnamectl set-hostname master-1
```

Ajouter sur **tous les nœuds** dans `/etc/hosts` :

```bash
sudo tee -a /etc/hosts <<EOF

# Cluster Kubernetes HA
192.168.1.10   master-1
192.168.1.11   master-2
192.168.1.12   master-3
192.168.1.20   worker-1
192.168.1.21   worker-2
192.168.1.100  k8s-vip
EOF
```

✅ Vérification :
```bash
ping -c 2 master-2
ping -c 2 k8s-vip
```

### 1.2 — Désactiver le swap

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#before-you-begin

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

✅ Vérification :
```bash
free -h
# La ligne "Swap:" doit afficher 0
```

### 1.3 — Modules kernel

> 📖 https://kubernetes.io/docs/setup/production-environment/container-runtimes/#prerequisite-ipvs-modules

```bash
sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

✅ Vérification :
```bash
lsmod | grep -E 'overlay|br_netfilter'
```

### 1.4 — Paramètres sysctl réseau

> 📖 https://kubernetes.io/docs/setup/production-environment/container-runtimes/#forwarding-ipv4-and-letting-iptables-see-bridged-traffic

```bash
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

✅ Vérification :
```bash
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
# Doit retourner 1 et 1
```

---

## PHASE 2 — Container Runtime : containerd (Tous les nœuds)

> 📖 https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd

### 2.1 — Installation

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y containerd.io
```

### 2.2 — Activer le cgroup driver systemd

> 📖 https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd-systemd

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

✅ Vérification :
```bash
grep 'SystemdCgroup' /etc/containerd/config.toml
# Doit retourner : SystemdCgroup = true
```

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl is-active containerd
# Doit retourner : active
```

---

## PHASE 3 — Installation kubeadm, kubelet, kubectl (Tous les nœuds)

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet
```

✅ Vérification :
```bash
kubeadm version
kubectl version --client
kubelet --version
# Doit afficher v1.34.x sur les 3 lignes
```

---

## PHASE 4 — Load Balancer : HAProxy + Keepalived (sur les 3 Masters)

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/#create-load-balancer-for-kube-apiserver

### 4.1 — Installation

```bash
sudo apt-get install -y haproxy keepalived
```

### 4.2 — Configuration HAProxy (identique sur les 3 masters)

```bash
sudo tee /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 2000
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 10s
    timeout client  1m
    timeout server  1m

frontend kubernetes-frontend
    bind *:6443
    mode tcp
    default_backend kubernetes-backend

backend kubernetes-backend
    mode    tcp
    balance roundrobin
    option  tcp-check
    server  master-1 192.168.1.10:6443 check fall 3 rise 2
    server  master-2 192.168.1.11:6443 check fall 3 rise 2
    server  master-3 192.168.1.12:6443 check fall 3 rise 2
EOF
```

### 4.3 — Configuration Keepalived sur master-1 (MASTER — détient la VIP)

```bash
sudo tee /etc/keepalived/keepalived.conf <<EOF
global_defs {
  router_id LVS_DEVEL
}

vrrp_script chk_haproxy {
  script "killall -0 haproxy"
  interval 2
  weight   2
}

vrrp_instance VI_1 {
  state   MASTER
  interface eth0          # ⚠️ Adapter à votre interface : ip a pour vérifier
  virtual_router_id 51
  priority  101           # Le plus élevé = obtient la VIP en premier
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass K8sH4Lab!
  }

  virtual_ipaddress {
    192.168.1.100
  }

  track_script {
    chk_haproxy
  }
}
EOF
```

### 4.4 — Configuration Keepalived sur master-2 (BACKUP)

```bash
sudo tee /etc/keepalived/keepalived.conf <<EOF
global_defs {
  router_id LVS_DEVEL
}

vrrp_script chk_haproxy {
  script "killall -0 haproxy"
  interval 2
  weight   2
}

vrrp_instance VI_1 {
  state   BACKUP
  interface eth0          # ⚠️ Adapter à votre interface
  virtual_router_id 51
  priority  100           # Inférieur à master-1
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass K8sH4Lab!
  }

  virtual_ipaddress {
    192.168.1.100
  }

  track_script {
    chk_haproxy
  }
}
EOF
```

### 4.5 — Configuration Keepalived sur master-3 (BACKUP)

```bash
sudo tee /etc/keepalived/keepalived.conf <<EOF
global_defs {
  router_id LVS_DEVEL
}

vrrp_script chk_haproxy {
  script "killall -0 haproxy"
  interval 2
  weight   2
}

vrrp_instance VI_1 {
  state   BACKUP
  interface eth0          # ⚠️ Adapter à votre interface
  virtual_router_id 51
  priority  99            # Le plus faible — dernier recours
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass K8sH4Lab!
  }

  virtual_ipaddress {
    192.168.1.100
  }

  track_script {
    chk_haproxy
  }
}
EOF
```

### 4.6 — Démarrage des services (sur les 3 masters)

```bash
sudo systemctl enable --now haproxy keepalived
```

✅ Vérifications :
```bash
# La VIP doit être visible uniquement sur master-1
ip addr show | grep 192.168.1.100

# HAProxy et Keepalived doivent être actifs sur les 3
sudo systemctl is-active haproxy keepalived

# Test de connectivité vers la VIP
# "Connection refused" est normal ici — l'API server n'est pas encore déployé
nc -vz 192.168.1.100 6443
```

---

## PHASE 5 — Initialisation du premier Master

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/#stacked-control-plane-and-etcd-nodes

Sur **master-1 uniquement** :

### 5.1 — Fichier de configuration kubeadm

```bash
cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.0
controlPlaneEndpoint: "k8s-vip:6443"    # Toujours la VIP — jamais l'IP directe d'un master
networking:
  podSubnet: "10.244.0.0/16"            # Plage pods — pas de conflit avec le réseau VM 192.168.x.x
  serviceSubnet: "10.96.0.0/12"         # Plage services K8s
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.1.10        # IP propre à master-1
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
EOF
```

### 5.2 — Pré-vérification

```bash
sudo kubeadm init phase preflight --config /tmp/kubeadm-config.yaml
# Doit terminer sans erreur (warnings acceptables)
```

### 5.3 — Initialisation du cluster

```bash
sudo kubeadm init \
  --config /tmp/kubeadm-config.yaml \
  --upload-certs \
  --v=5 2>&1 | tee /tmp/kubeadm-init.log
```

> ⚠️ **CRITIQUE :** Sauvegarder toute la sortie dans `/tmp/kubeadm-init.log`.  
> Elle contient les commandes `kubeadm join` pour les masters et les workers.  
> Le `--certificate-key` expire après **2 heures**.

### 5.4 — Configurer kubectl sur master-1

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

✅ Vérifications :
```bash
kubectl get nodes
# master-1 en NotReady — normal, le CNI n'est pas encore installé

kubectl get pods -n kube-system
# CoreDNS en Pending — normal, attend le CNI
```

---

## PHASE 6 — CNI : Calico (depuis master-1)

> 📖 https://kubernetes.io/docs/concepts/cluster-administration/addons/  
> 📖 https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart

```bash
# Opérateur Tigera
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml

# Télécharger la configuration custom pour vérifier le podCIDR
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/custom-resources.yaml

# S'assurer que le CIDR correspond à notre podSubnet 10.244.0.0/16
grep cidr custom-resources.yaml
# Si différent de 10.244.0.0/16 :
sed -i 's|192.168.0.0/16|10.244.0.0/16|' custom-resources.yaml

kubectl create -f custom-resources.yaml
```

✅ Vérifications :
```bash
watch kubectl get pods -n calico-system
# Attendre que tous les pods soient Running (~2-3 minutes)

kubectl get nodes
# master-1 passe en Ready ✅
```

---

## PHASE 7 — Joindre les Masters 2 et 3

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/#stacked-control-plane-and-etcd-nodes

Récupérer la commande `join` pour les **control-plane** depuis `/tmp/kubeadm-init.log`.
Elle ressemble à :

```
kubeadm join k8s-vip:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key>
```

### Sur master-2

```bash
sudo kubeadm join k8s-vip:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key> \
  --apiserver-advertise-address 192.168.1.11

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Sur master-3

```bash
sudo kubeadm join k8s-vip:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key> \
  --apiserver-advertise-address 192.168.1.12

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

✅ Vérifications depuis master-1 :
```bash
kubectl get nodes
# Les 3 masters doivent être Ready avec le rôle control-plane

# Vérifier le quorum etcd — les 3 membres doivent être "started"
kubectl -n kube-system exec -it etcd-master-1 -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert   /etc/kubernetes/pki/etcd/peer.crt \
  --key    /etc/kubernetes/pki/etcd/peer.key \
  member list
```

---

## PHASE 8 — Joindre les Workers

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#join-nodes

Récupérer la commande `join` pour les **workers** depuis `/tmp/kubeadm-init.log`.
Elle ressemble à (sans `--control-plane` ni `--certificate-key`) :

```
kubeadm join k8s-vip:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

> ⏱️ Le token expire après **24 heures**. Pour en créer un nouveau :
> ```bash
> kubeadm token create --print-join-command
> ```

### Sur worker-1 et worker-2

```bash
sudo kubeadm join k8s-vip:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

✅ Vérification finale depuis master-1 :
```bash
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           AGE   VERSION   INTERNAL-IP
master-1   Ready    control-plane   20m   v1.34.x   192.168.1.10
master-2   Ready    control-plane   12m   v1.34.x   192.168.1.11
master-3   Ready    control-plane   8m    v1.34.x   192.168.1.12
worker-1   Ready    <none>          3m    v1.34.x   192.168.1.20
worker-2   Ready    <none>          2m    v1.34.x   192.168.1.21
```

🎉 **Le cluster est opérationnel !**

---

## PHASE 9 — Démonstration de la Haute Disponibilité

> 📖 https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/

### 9.1 — Déployer une application de test

```bash
kubectl create deployment demo-app --image=nginx --replicas=4
kubectl expose deployment demo-app --port=80 --type=NodePort

kubectl get pods -o wide
# Les pods doivent être répartis sur worker-1 et worker-2

kubectl get svc demo-app
# Noter le NodePort (ex: 32000)
curl http://192.168.1.20:<NodePort>
```

### 9.2 — 🎬 DEMO HA : Simuler la perte de master-1

```bash
# AVANT : Vérifier que la VIP est sur master-1
ip addr show | grep 192.168.1.100   # sur master-1

# Simuler une panne de master-1
sudo systemctl stop kubelet haproxy keepalived

# DEPUIS MASTER-2 : le cluster doit rester opérationnel
kubectl get nodes
kubectl get pods -A

# La VIP a basculé automatiquement sur master-2
ip addr show | grep 192.168.1.100   # sur master-2 — doit apparaître maintenant

# L'application continue de répondre sans interruption
curl http://192.168.1.20:<NodePort>   # ✅ toujours accessible

# Remettre master-1 en ligne
sudo systemctl start kubelet haproxy keepalived
# master-1 reprend la VIP (priorité plus haute)
```

### 9.3 — Vérifier les certificats

> 📖 https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/

```bash
kubeadm certs check-expiration
# Tous les certificats affichent leur date d'expiration (~1 an)
```

---

## PHASE 10 — Opérations post-déploiement

### 10.1 — Sauvegarde etcd

> 📖 https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd-backup-$(date +%Y%m%d-%H%M).db

# Vérifier le snapshot
ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup-*.db --write-out=table
```

### 10.2 — Accès kubectl depuis une machine externe

```bash
scp user@192.168.1.10:/etc/kubernetes/admin.conf ~/.kube/config
# Pointer sur la VIP pour profiter de la HA
sed -i 's/192.168.1.10:6443/192.168.1.100:6443/' ~/.kube/config
kubectl get nodes
```

---

## 🛠️ Dépannage rapide

```bash
# Logs kubelet
sudo journalctl -u kubelet -f --since "5 minutes ago"

# Logs d'un composant système
kubectl logs -n kube-system kube-apiserver-master-1

# Reset complet d'un nœud (si join raté)
sudo kubeadm reset
sudo rm -rf /etc/cni/net.d /var/lib/etcd
sudo iptables -F && sudo iptables -t nat -F

# Nouveau token join (expiré après 24h)
kubeadm token create --print-join-command

# Tester DNS interne
kubectl run test-dns --image=busybox --restart=Never -- nslookup kubernetes.default
kubectl logs test-dns && kubectl delete pod test-dns
```

---

## 📚 Références Documentation Officielle K8s

| Étape | Documentation |
|-------|--------------|
| Pré-requis | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ |
| Container Runtimes | https://kubernetes.io/docs/setup/production-environment/container-runtimes/ |
| Cluster HA kubeadm | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/ |
| Topologies HA | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/ |
| Créer un cluster | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ |
| Gestion certificats | https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/ |
| Sauvegarde etcd | https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/ |
| Addons réseau | https://kubernetes.io/docs/concepts/cluster-administration/addons/ |

---

> ⚠️ **Avant de commencer :** Vérifier le nom de votre interface réseau avec `ip a`
> et remplacer `eth0` dans les configs Keepalived. Les IPs sont des exemples — adapter à votre réseau.
