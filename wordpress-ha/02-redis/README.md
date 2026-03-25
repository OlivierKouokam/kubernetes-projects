# Phase 2 — Redis HA avec RedisSentinel (OT-SCNG Operator)

## Architecture déployée

```
wordpress-ha (namespace)
│
└── RedisSentinel "redis-sentinel"
    │
    ├── redis-sentinel-0  (Master   — R/W, port 6379)
    ├── redis-sentinel-1  (Replica  — R/O, réplique du master)
    ├── redis-sentinel-2  (Replica  — R/O, réplique du master)
    │
    ├── sentinel-0  ┐
    ├── sentinel-1  ├─ Quorum=2 : 2 votes suffisent pour élire un nouveau master
    └── sentinel-2  ┘
        Port 26379 — détection de panne + failover automatique

redis-operator (namespace)
└── redis-operator deployment (opérateur OT-SCNG)
```

### Fonctionnement du failover

```
1. Master tombe (pod crash, nœud KO...)
       ↓
2. Sentinels détectent l'absence (après 5s — downAfterMilliseconds)
       ↓
3. Vote Sentinel : 2 voix sur 3 (quorum=2) → consensus atteint
       ↓
4. Un replica est promu Master automatiquement (< 15s total)
       ↓
5. WordPress se reconnecte via le nom logique "mymaster"
   (le plugin Redis Object Cache interroge les Sentinels
    pour découvrir l'adresse du nouveau master)
       ↓
6. L'ancien master redémarre en Replica du nouveau master
```

## Fichiers

```
02-redis/
├── deploy-redis.sh                      ← Script de déploiement complet
├── verify-redis.sh                      ← Vérification & tests failover
├── operator/
│   └── values-redis-operator.yaml       ← Config Helm de l'opérateur
├── cluster/
│   ├── redis-sentinel-cr.yaml           ← CR RedisSentinel (topologie HA)
│   ├── redis-config.yaml                ← ConfigMap tuning Redis (LRU, maxmemory...)
│   └── redis-nodeport-test.yaml         ← NodePort test (master + sentinel)
└── secrets/
    └── redis-secret.yaml                ← Password Redis
```

## Déploiement

### Option A — Script automatisé
```bash
cd 02-redis/
chmod +x deploy-redis.sh verify-redis.sh
./deploy-redis.sh
```

### Option B — Étape par étape

#### 1. Repo Helm OT-SCNG
```bash
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/
helm repo update
helm search repo ot-helm/redis-operator
```

#### 2. Installer l'opérateur Redis
```bash
kubectl create namespace redis-operator
helm install redis-operator ot-helm/redis-operator \
  --namespace redis-operator \
  --values operator/values-redis-operator.yaml \
  --wait
```

#### 3. Secret + ConfigMap
```bash
kubectl apply -f secrets/redis-secret.yaml
kubectl apply -f cluster/redis-config.yaml
```

#### 4. Déployer le cluster RedisSentinel
```bash
kubectl apply -f cluster/redis-sentinel-cr.yaml

# Surveiller le démarrage
kubectl get pods -n wordpress-ha -l app=redis-sentinel -w
```

#### 5. NodePort test
```bash
kubectl apply -f cluster/redis-nodeport-test.yaml
```

## Vérification

```bash
./verify-redis.sh
```

Ou manuellement :

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Ping master
redis-cli -h $NODE_IP -p 30379 -a 'RedisSent!n3l2024' ping

# Info réplication
redis-cli -h $NODE_IP -p 30379 -a 'RedisSent!n3l2024' INFO replication

# Master actuel selon Sentinel
redis-cli -h $NODE_IP -p 30380 SENTINEL get-master-addr-by-name mymaster

# Lister les replicas
redis-cli -h $NODE_IP -p 30380 SENTINEL replicas mymaster
```

### Via pod temporaire (sans redis-cli local)
```bash
kubectl run redis-test --image=redis:7.2-alpine --rm -it --restart=Never \
  -n wordpress-ha \
  -- redis-cli -h redis-sentinel-master-service -p 6379 \
     -a 'RedisSent!n3l2024' INFO replication
```

## Test de failover

```bash
# 1. Identifier le master actuel
kubectl get pods -n wordpress-ha -l redis-role=master

# 2. Simuler une panne (supprimer le master)
kubectl delete pod redis-sentinel-0 -n wordpress-ha

# 3. Observer la réélection en temps réel (< 15 secondes)
watch redis-cli -h $NODE_IP -p 30380 SENTINEL get-master-addr-by-name mymaster

# 4. Vérifier que le nouveau master accepte les écritures
redis-cli -h $NODE_IP -p 30379 -a 'RedisSent!n3l2024' SET test:after:failover ok

# 5. L'ancien master redémarre en replica
kubectl get pods -n wordpress-ha -l app=redis-sentinel -w
```

## Endpoints internes pour WordPress (Phase 4)

| Service | Port | Usage |
|---------|------|-------|
| `redis-sentinel-service` | 26379 | Sentinel — découverte du master |
| `redis-sentinel-master-service` | 6379 | Connexion directe master (R/W) |

### Configuration wp-config.php (Phase 4)
```php
// Plugin Redis Object Cache — mode Sentinel
define('WP_REDIS_CLIENT', 'predis');
define('WP_REDIS_SENTINEL', 'mymaster');
define('WP_REDIS_SENTINELS', [
    'tcp://redis-sentinel-service:26379',
]);
define('WP_REDIS_PASSWORD', 'RedisSent!n3l2024');
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
```

## Credentials par défaut (À CHANGER en production)

| Variable | Valeur |
|----------|--------|
| Redis password | `RedisSent!n3l2024` |
| Master name | `mymaster` |
| Sentinel port | `26379` |

## Troubleshooting

```bash
# Logs opérateur Redis
kubectl logs -n redis-operator deployment/redis-operator -f

# Logs d'un pod Redis
kubectl logs -n wordpress-ha redis-sentinel-0 -c redis -f

# Logs d'un pod Sentinel
kubectl logs -n wordpress-ha redis-sentinel-0 -c sentinel -f

# Événements namespace
kubectl get events -n wordpress-ha --sort-by='.lastTimestamp' --field-selector=type=Warning

# Décrire le CR RedisSentinel
kubectl describe redissentinel redis-sentinel -n wordpress-ha
```
