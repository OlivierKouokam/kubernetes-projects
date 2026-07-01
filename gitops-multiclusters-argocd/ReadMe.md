# 📖 README : Guide de Validation du Lab GitOps Multi-Cluster

Ce guide vous permet de tester de bout en bout l'architecture **Hub and Spoke** avec ArgoCD avant de passer à l'enregistrement des vidéos.

### 🗺️ Rappel de la topographie du Lab
* **k8s-hub** : `192.168.99.10` (Gestion & ArgoCD)
* **k8s-staging** : `192.168.99.11` (Environnement cible Recette)
* **k8s-prod** : `192.168.99.12` (Environnement cible Production)

---

## 🛠️ Étape 01 à 02 : Initialisation et Structure Git

### 1. Démarrer les environnements
Depuis le dossier contenant votre `Vagrantfile`, lancez le déploiement de vos trois clusters :
```bash
vagrant up
```

### 2. Structure cible du dépôt Git (À créer sur votre GitHub/GitLab)
Créez un dépôt nommé k8s-gitops-infra avec l'arborescence suivante :

├── apps/
│   ├── base/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── staging/
│       │   ├── kustomization.yaml
│       │   └── patches-replica.yaml
│       └── prod/
│           ├── kustomization.yaml
│           └── patches-replica.yaml
└── argocd/
    └── applicationset.yaml

---

## 🚀 Étape 03 à 04 : Installation et Accès à ArgoCD (Sur k8s-hub)

### 1. Connectez-vous sur le Hub et passez en root

```bash
vagrant ssh k8s-hub
sudo su -
```

### 2. Déployer ArgoCD

```bash
# Création du namespace
kubectl create namespace argocd

# Installation de la version stable non-HA
kubectl apply -n argocd -f [https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml](https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml)

# Attendre que tous les pods soient opérationnels
kubectl get pods -n argocd -w
```

### 3. Exposer l'interface et récupérer les accès

```bash
# Exposer le serveur ArgoCD via un NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# Récupérer le port assigné par Kubernetes (Cherchez le port en face du 443)
kubectl get svc argocd-server -n argocd

# Extraire le mot de passe admin initial chiffré
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Ouvrez votre navigateur sur https://192.168.99.10:<NODE_PORT>, connectez-vous avec le compte admin, puis modifiez le mot de passe dans les paramètres.

## 🔗 Étape 05 à 06 : Connexion des Clusters Distants (Depuis k8s-hub)

### 1. Télécharger la CLI ArgoCD sur le Hub

```bash
curl -sSL -o /usr/local/bin/argocd [https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64](https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64)
chmod +x /usr/local/bin/argocd
```

### 2. Récupérer et nettoyer les Kubeconfigs distants

Depuis le terminal du k8s-hub (en tant que root), exécutez ces commandes :

```bash
mkdir -p ~/.kube/remote-configs

# Récupération du Kubeconfig de Staging
ssh -o StrictHostKeyChecking=no vagrant@192.168.99.11 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/remote-configs/staging.conf

# Récupération du Kubeconfig de Prod
ssh -o StrictHostKeyChecking=no vagrant@192.168.99.12 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/remote-configs/prod.conf

# Correction des adresses locales (Remplacer 127.0.0.1 par l'IP réelle de la VM cible)
sed -i 's/127.0.0.1/192.168.99.11/g' ~/.kube/remote-configs/staging.conf
sed -i 's/127.0.0.1/192.168.99.12/g' ~/.kube/remote-configs/prod.conf
```

### 3. Ajouter les clusters dans ArgoCD

```bash
# Connexion à la CLI ArgoCD locale
argocd login 127.0.0.1:443 --username admin --password <VOTRE_NOUVEAU_MDP> --insecure

# Déclarer le cluster Staging
KUBECONFIG=~/.kube/remote-configs/staging.conf argocd cluster add kubernetes-admin@kubernetes --name k8s-staging

# Déclarer le cluster Prod
KUBECONFIG=~/.kube/remote-configs/prod.conf argocd cluster add kubernetes-admin@kubernetes --name k8s-prod
```

## 🛠️ Étape 08 à 09 : Kustomize & ApplicationSets

### 1. Fichier argocd/applicationset.yaml (À pousser sur votre Git)

```bash
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: web-app-multicluster
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - cluster: k8s-staging
            url: [https://192.168.99.11:6443](https://192.168.99.11:6443)
            env: staging
          - cluster: k8s-prod
            url: [https://192.168.99.12:6443](https://192.168.99.12:6443)
            env: prod
  template:
    metadata:
      name: '{{env}}-web-app'
    spec:
      project: default
      source:
        repoURL: '[https://github.com/](https://github.com/)<votre-user>/k8s-gitops-infra.git'
        targetRevision: HEAD
        path: apps/overlays/{{env}}
      destination:
        server: '{{url}}'
        namespace: default
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### 2. Appliquer l'ApplicationSet (Depuis k8s-hub)

```bash
kubectl apply -f argocd/applicationset.yaml
```

## 🚨 Étape 10 & 12 : Crash Test (Validation du Self-Healing)

### 1. Vérifier le déploiement sur le cluster de Production

```bash
vagrant ssh k8s-prod
sudo su -
kubectl get pods
```

### 2. Saboter manuellement l'infrastructure depuis la VM de Prod

```bash
# Réduire brutalement le déploiement à 0 réplica directement sur le cluster de prod
kubectl scale deployment/web-app --replicas=0
```

Observez l'interface web d'ArgoCD : l'application repasse immédiatement en Synced et recrée automatiquement les pods sur la VM de Prod.

## 💾 Étape 13 : Sauvegarde de la configuration

```bash
# À exécuter depuis la VM k8s-hub
argocd-util admin export -n argocd > /tmp/argocd-backup-final.yaml

# Vérifier que le fichier est correctement généré
cat /tmp/argocd-backup-final.yaml | grep -E "kind:|name:" | head -n 20
```

## 🔒 Étape 14 : Sauvegarde de l'état du Lab (Snapshots)

```bash
# Quitter la VM, revenir sur votre machine hôte et exécuter :
vagrant halt

# Sauvegarder l'état complet sous VirtualBox via Vagrant
vagrant snapshot save "lab-module02-gitops-ok"
```
