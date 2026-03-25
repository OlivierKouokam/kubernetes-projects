# Phase 3 — MinIO HA avec MinIO Operator (Erasure Coding)

## Architecture déployée

```
wordpress-ha (namespace)
│
└── Tenant "minio-tenant"
    │
    ├── minio-tenant-pool-0-0  ─┐
    ├── minio-tenant-pool-0-1   ├─ Pool de 4 serveurs
    ├── minio-tenant-pool-0-2   │  2 drives chacun
    └── minio-tenant-pool-0-3  ─┘
        │
        ├── 8 PVCs NFS (2Gi × 8 = 16Gi brut)
        │
        └── Erasure Coding EC:4
            ├── 4 drives data     → ~8Gi utilisable
            └── 4 drives parité   → tolérance perte 2 pods simultanés

        Bucket : wp-uploads  (médias WordPress)
        User   : wp-minio-user  (accès restreint à wp-uploads)

minio-operator (namespace)
└── minio-operator deployment
```

### Pourquoi 4 pods minimum ?

MinIO nécessite au minimum 4 nœuds (pods) pour activer l'erasure coding distribué.
Avec EC:4 sur 8 drives :
- **Data shards** : 4 (données réelles)
- **Parity shards** : 4 (redondance)
- **Tolérance** : perte de jusqu'à 4 drives ou 2 pods simultanément
- **Espace utile** : 50% de l'espace brut (8Gi utilisables sur 16Gi)

## Fichiers

```
03-minio/
├── deploy-minio.sh                       ← Script de déploiement complet
├── verify-minio.sh                       ← Vérification & tests résilience
├── operator/
│   └── values-minio-operator.yaml        ← Config Helm de l'opérateur
├── tenant/
│   ├── minio-tenant-cr.yaml              ← CR Tenant (topologie HA)
│   └── minio-nodeport-test.yaml          ← NodePort API S3 + Console
├── buckets/
│   ├── minio-init-configmap.yaml         ← Script init + politique IAM
│   └── minio-init-job.yaml               ← Job init bucket + user WP
└── secrets/
    └── minio-secrets.yaml                ← Root + WordPress credentials
```

## Déploiement

### Option A — Script automatisé
```bash
cd 03-minio/
chmod +x deploy-minio.sh verify-minio.sh
./deploy-minio.sh
```

### Option B — Étape par étape

#### 1. Repo Helm MinIO Operator
```bash
helm repo add minio-operator https://operator.min.io/
helm repo update
```

#### 2. Installer l'opérateur
```bash
kubectl create namespace minio-operator
helm install minio-operator minio-operator/operator \
  --namespace minio-operator \
  --values operator/values-minio-operator.yaml \
  --wait
```

#### 3. Secrets
```bash
kubectl apply -f secrets/minio-secrets.yaml
```

#### 4. Déployer le Tenant
```bash
kubectl apply -f tenant/minio-tenant-cr.yaml

# Surveiller le démarrage
kubectl get tenant minio-tenant -n wordpress-ha -w
kubectl get pods -n wordpress-ha -l v1.min.io/tenant=minio-tenant -w
```

#### 5. Attendre health=green
```bash
watch kubectl get tenant minio-tenant -n wordpress-ha
# Attendre : HEALTH = green
```

#### 6. Init bucket + user WordPress
```bash
kubectl apply -f buckets/minio-init-configmap.yaml
kubectl apply -f buckets/minio-init-job.yaml
kubectl logs -n wordpress-ha job/minio-init -f
```

#### 7. NodePorts test
```bash
kubectl apply -f tenant/minio-nodeport-test.yaml
```

## Accès console MinIO

```
URL      : http://<NODE_IP>:30901
Login    : minio
Password : MinIOr00t!2024
```

## Test avec mc (MinIO Client)

```bash
# Installer mc
curl -O https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc && sudo mv mc /usr/local/bin/

# Configurer alias
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
mc alias set wplab http://$NODE_IP:30900 minio MinIOr00t!2024

# Vérifier le cluster
mc admin info wplab

# Lister les buckets
mc ls wplab/

# Tester upload
echo "test-media" | mc pipe wplab/wp-uploads/test.txt
mc ls wplab/wp-uploads/

# Tester l'user WordPress
mc alias set wpminio http://$NODE_IP:30900 wp-minio-user WPMinIO!S3c2024
mc ls wpminio/wp-uploads/
echo "wp-test" | mc pipe wpminio/wp-uploads/wp-test.txt
```

## Test de résilience

```bash
# Supprimer 1 pod (toujours disponible)
kubectl delete pod minio-tenant-pool-0-0 -n wordpress-ha
curl http://$NODE_IP:30900/minio/health/live   # doit répondre 200

# Supprimer 2 pods (limite — toujours disponible en EC:4)
kubectl delete pod minio-tenant-pool-0-0 minio-tenant-pool-0-1 -n wordpress-ha

# Surveiller le retour à la normale
watch kubectl get tenant minio-tenant -n wordpress-ha
```

## Endpoints internes pour WordPress (Phase 4)

| Paramètre | Valeur |
|-----------|--------|
| Endpoint API S3 | `http://minio-tenant-hl.wordpress-ha.svc.cluster.local:9000` |
| Bucket | `wp-uploads` |
| Region | `us-east-1` |
| Access Key | `wp-minio-user` |
| Secret Key | `WPMinIO!S3c2024` |
| Force Path Style | `true` (obligatoire avec MinIO) |
| URL publique | `http://<NODE_IP>:30900/wp-uploads` |

## Credentials par défaut (À CHANGER en production)

| Compte | Access Key | Secret Key |
|--------|-----------|------------|
| Root MinIO | `minio` | `MinIOr00t!2024` |
| WordPress | `wp-minio-user` | `WPMinIO!S3c2024` |

## Troubleshooting

```bash
# Logs opérateur
kubectl logs -n minio-operator deployment/minio-operator -f

# Logs d'un pod MinIO
kubectl logs -n wordpress-ha minio-tenant-pool-0-0 -f

# Statut détaillé du Tenant
kubectl describe tenant minio-tenant -n wordpress-ha

# Logs Job init
kubectl logs -n wordpress-ha job/minio-init

# Relancer le Job si besoin
kubectl delete job minio-init -n wordpress-ha
kubectl apply -f buckets/minio-init-job.yaml

# Health check direct
curl http://<NODE_IP>:30900/minio/health/live
curl http://<NODE_IP>:30900/minio/health/cluster
```
