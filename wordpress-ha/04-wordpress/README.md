# Phase 4 — WordPress HA (Stateless + Redis + MinIO)

## Architecture complète

```
                    ┌─────────────────────────────────────┐
                    │         namespace: wordpress-ha      │
                    │                                     │
         :30080     │  ┌──────────────────────────────┐   │
  User ──────────────→ │   WordPress Deployment        │   │
                    │  │   2–10 replicas (HPA)         │   │
                    │  │   stateless — aucun PVC       │   │
                    │  └──────┬──────────┬───────┬────┘   │
                    │         │          │       │         │
                    │    MySQL │    Redis │  MinIO│         │
                    │         ▼          ▼       ▼         │
                    │  ┌──────────┐ ┌────────┐ ┌────────┐ │
                    │  │InnoDB    │ │Redis   │ │MinIO   │ │
                    │  │Cluster   │ │Sentinel│ │Tenant  │ │
                    │  │(Phase 1) │ │(Phase 2│ │(Phase 3│ │
                    │  └──────────┘ └────────┘ └────────┘ │
                    └─────────────────────────────────────┘
```

### Pourquoi WordPress est stateless ici

Sans MinIO, chaque pod WordPress aurait besoin d'un PVC `ReadWriteMany`
(NFS partagé) pour les uploads — compliqué et lent.

Avec **WP Offload Media** : dès qu'un media est uploadé, il est
immédiatement transféré vers MinIO et servi depuis là. Chaque pod
WordPress peut donc être créé/détruit librement sans perte de données.

### Flux d'une requête

```
1. Visiteur → NodePort :30080 → pod WordPress (round-robin)
2. WordPress cherche la page en cache Redis
   └─ Cache hit  → réponse immédiate (< 5ms)
   └─ Cache miss → requête MySQL → mise en cache Redis → réponse
3. Images/médias → URL MinIO directement (bucket wp-uploads)
```

## Fichiers

```
04-wordpress/
├── deploy-wordpress.sh                      ← Script déploiement complet
├── verify-wordpress.sh                      ← Vérification + tests résilience
├── secrets/
│   └── wordpress-secrets.yaml              ← Tous les credentials
├── configmaps/
│   └── wp-config-configmap.yaml            ← wp-config.php (Redis + MinIO)
├── deployment/
│   ├── wordpress-deployment.yaml           ← Deployment stateless + init containers
│   ├── wordpress-service.yaml              ← NodePort :30080
│   └── wordpress-pdb.yaml                  ← PodDisruptionBudget
├── hpa/
│   └── wordpress-hpa.yaml                  ← HPA CPU/mémoire (min=2, max=10)
└── plugins/
    └── wordpress-postconfigure-job.yaml    ← WP-CLI : activation Redis + S3
```

## Déploiement

### ⚠️ Avant de déployer — modifier les secrets

```bash
# 1. Générer les Auth Salts WordPress
curl -s https://api.wordpress.org/secret-key/1.1/salt/

# 2. Coller les valeurs dans secrets/wordpress-secrets.yaml
# 3. Changer le mot de passe admin dans plugins/wordpress-postconfigure-job.yaml
```

### Option A — Script automatisé
```bash
cd 04-wordpress/
chmod +x deploy-wordpress.sh verify-wordpress.sh
./deploy-wordpress.sh
```

### Option B — Étape par étape

```bash
# Secrets + ConfigMap
kubectl apply -f secrets/wordpress-secrets.yaml
kubectl apply -f configmaps/wp-config-configmap.yaml

# Deployment + Service + PDB
kubectl apply -f deployment/wordpress-deployment.yaml
kubectl apply -f deployment/wordpress-service.yaml
kubectl apply -f deployment/wordpress-pdb.yaml

# Attendre que WordPress soit Ready
kubectl rollout status deployment/wordpress -n wordpress-ha --timeout=15m

# HPA
kubectl apply -f hpa/wordpress-hpa.yaml

# Post-configuration (activation plugins via WP-CLI)
kubectl apply -f plugins/wordpress-postconfigure-job.yaml
kubectl logs -n wordpress-ha job/wordpress-postconfigure -f
```

## Vérifications post-déploiement

```bash
./verify-wordpress.sh
```

### Checklist manuelle dans wp-admin

1. **Redis Object Cache** : Réglages → Redis Object Cache
   - Status doit afficher : **Connected** (vert)
   - Si non connecté : cliquer "Activer le cache objet"

2. **WP Offload Media** : Médias → Offload Media Settings
   - Provider : Amazon S3 (compatible MinIO)
   - Bucket : `wp-uploads`
   - Region : `us-east-1`
   - Custom endpoint : `http://minio-tenant-hl.wordpress-ha.svc.cluster.local:9000`
   - Force path style : ✓ activé

3. **Test upload media** : Médias → Ajouter
   - Uploader une image
   - Vérifier dans MinIO Console (`http://<NODE_IP>:30901`)
   - que l'image apparaît dans le bucket `wp-uploads`

## Tests de scaling

```bash
# Scale up manuel
kubectl scale deployment/wordpress -n wordpress-ha --replicas=5

# Observer le scaling
kubectl get pods -n wordpress-ha -l app=wordpress -w

# Vérifier que le site reste accessible pendant le scaling
watch curl -s -o /dev/null -w "%{http_code}" http://<NODE_IP>:30080/

# Observer le HPA (nécessite metrics-server)
kubectl get hpa wordpress-hpa -n wordpress-ha -w
```

## Tests de résilience de la stack complète

```bash
NODE_IP=<NODE_IP>

# Test 1 — Panne pod WordPress → les autres prennent le relais
kubectl delete pod $(kubectl get pods -n wordpress-ha -l app=wordpress \
  -o jsonpath='{.items[0].metadata.name}') -n wordpress-ha
# Site doit rester accessible

# Test 2 — Failover MySQL (< 30s)
kubectl delete pod mycluster-0 -n wordpress-ha
watch curl -s -o /dev/null -w "%{http_code}" http://${NODE_IP}:30080/

# Test 3 — Failover Redis (< 15s)
kubectl delete pod redis-sentinel-0 -n wordpress-ha
# WordPress re-builde le cache depuis MySQL — légère latence

# Test 4 — Panne pod MinIO
kubectl delete pod minio-tenant-pool-0-0 -n wordpress-ha
# Les médias restent accessibles grâce à EC:4

# Test 5 — Drain d'un nœud complet
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data
# Le PDB garantit au moins 1 pod WP disponible pendant le drain
```

## Credentials (À changer en production)

| Service | User | Password | Port |
|---------|------|----------|------|
| WordPress Admin | `admin` | `WPadmin!2024` | 30080 |
| MySQL root | `root` | `WPr00tS3cur3!2024` | 30306 |
| MySQL WordPress | `wordpress` | `WPdbP@ss2024!` | 30306 |
| Redis | — | `RedisSent!n3l2024` | 30379/30380 |
| MinIO root | `minio` | `MinIOr00t!2024` | 30900/30901 |
| MinIO WP user | `wp-minio-user` | `WPMinIO!S3c2024` | 30900 |

## Troubleshooting

```bash
# Logs WordPress
kubectl logs -n wordpress-ha -l app=wordpress -f

# Logs d'un pod spécifique + init containers
kubectl logs -n wordpress-ha <pod-name> -c wait-for-mysql
kubectl logs -n wordpress-ha <pod-name> -c install-plugins
kubectl logs -n wordpress-ha <pod-name> -c wordpress

# WP-CLI interactif depuis un pod WordPress
kubectl exec -it -n wordpress-ha \
  $(kubectl get pods -n wordpress-ha -l app=wordpress \
    -o jsonpath='{.items[0].metadata.name}') \
  -- wp --allow-root --path=/var/www/html redis status

# Décrire le Deployment (events)
kubectl describe deployment wordpress -n wordpress-ha

# Redémarrer tous les pods (rolling restart)
kubectl rollout restart deployment/wordpress -n wordpress-ha
```
