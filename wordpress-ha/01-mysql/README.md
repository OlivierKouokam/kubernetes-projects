# Phase 1 — MySQL HA avec MySQL Operator (Oracle)

## Architecture déployée

```
wordpress-ha (namespace)
│
└── InnoDB Cluster "mycluster"
    ├── mycluster-0  (Primary   — R/W)
    ├── mycluster-1  (Secondary — R/O replica)
    ├── mycluster-2  (Secondary — R/O replica)
    │
    ├── MySQLRouter  (×2 pods — routing automatique R/W / R/O)
    │   ├── Port 6446 → Primary (R/W)
    │   └── Port 6447 → Secondary round-robin (R/O)
    │
    └── PVCs (×3, 5Gi chacun via StorageClass example-nfs)

mysql-operator (namespace)
└── mysql-operator deployment (opérateur Oracle)
```

## Fichiers

```
01-mysql/
├── namespace.yaml                      ← Namespace wordpress-ha
├── deploy-mysql.sh                     ← Script de déploiement complet
├── verify-mysql.sh                     ← Vérification & diagnostics
├── operator/
│   └── values-mysql-operator.yaml      ← Config Helm de l'opérateur
├── cluster/
│   ├── values-innodbcluster.yaml       ← Config Helm du cluster InnoDB
│   ├── mysql-initdb-configmap.yaml     ← Script SQL d'init WordPress
│   ├── mysql-initdb-job.yaml           ← Job d'init base WordPress
│   └── mysql-nodeport-test.yaml        ← NodePort pour tests (temp)
└── secrets/
    └── mysql-secret.yaml               ← Credentials (à changer !)
```

## Déploiement

### Option A — Script automatisé
```bash
cd 01-mysql/
chmod +x deploy-mysql.sh verify-mysql.sh
./deploy-mysql.sh
```

### Option B — Étape par étape

#### 1. Namespace
```bash
kubectl apply -f namespace.yaml
```

#### 2. Repo Helm MySQL Operator
```bash
helm repo add mysql-operator https://mysql.github.io/mysql-operator/
helm repo update
helm search repo mysql-operator
```

#### 3. Installer l'opérateur Oracle
```bash
kubectl create namespace mysql-operator
helm install mysql-operator mysql-operator/mysql-operator \
  --namespace mysql-operator \
  --values operator/values-mysql-operator.yaml \
  --wait
```

#### 4. Créer le Secret MySQL
```bash
# ⚠️  Modifier les mots de passe si besoin avant d'appliquer
kubectl apply -f secrets/mysql-secret.yaml
```

#### 5. Déployer le cluster InnoDB
```bash
helm install mycluster mysql-operator/mysql-innodbcluster \
  --namespace wordpress-ha \
  --values cluster/values-innodbcluster.yaml \
  --wait --timeout 15m
```

#### 6. Attendre que le cluster soit ONLINE
```bash
# Surveiller le statut en temps réel
watch kubectl get innodbcluster -n wordpress-ha

# Ou en boucle
kubectl get innodbcluster mycluster -n wordpress-ha -w
```

#### 7. Initialiser la base WordPress
```bash
kubectl apply -f cluster/mysql-initdb-configmap.yaml
kubectl apply -f cluster/mysql-initdb-job.yaml

# Suivre les logs du Job
kubectl logs -n wordpress-ha job/mysql-initdb -f
```

#### 8. NodePort de test
```bash
kubectl apply -f cluster/mysql-nodeport-test.yaml
```

## Vérification

```bash
./verify-mysql.sh
```

Ou manuellement :

```bash
# Statut global
kubectl get innodbcluster -n wordpress-ha
kubectl get pods -n wordpress-ha
kubectl get pvc -n wordpress-ha
kubectl get svc -n wordpress-ha

# Membres du Group Replication (via pod temporaire)
kubectl run mysql-client --image=mysql:9.1 --rm -it --restart=Never \
  -n wordpress-ha \
  -- mysql -h mycluster-router-service -P 6446 \
     -u root -pWPr00tS3cur3!2024 \
     -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE \
         FROM performance_schema.replication_group_members;"
```

## Test de failover

```bash
# 1. Identifier le primary actuel
kubectl get pods -n wordpress-ha \
  -l mysql.oracle.com/cluster=mycluster \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.mysql\.oracle\.com/cluster-role'

# 2. Supprimer le primary (simule une panne)
kubectl delete pod mycluster-0 -n wordpress-ha

# 3. Observer la réélection automatique (doit prendre < 30s)
kubectl get pods -n wordpress-ha -w

# 4. Vérifier que le nouveau primary est opérationnel
kubectl get innodbcluster mycluster -n wordpress-ha
```

## Services internes pour WordPress (Phase 4)

| Service | Port | Usage |
|---------|------|-------|
| `mycluster-router-service` | 3306 / 6446 | R/W — connexion WordPress |
| `mycluster-router-service` | 6447 | R/O — lectures seules |

WordPress utilisera la connexion string :
```
host: mycluster-router-service
port: 3306
database: wordpress_db
user: wordpress
password: (depuis Secret mysql-credentials)
```

## Credentials par défaut (À CHANGER en production)

| Variable | Valeur |
|----------|--------|
| Root password | `WPr00tS3cur3!2024` |
| WordPress user | `wordpress` |
| WordPress password | `WPdbP@ss2024!` |
| WordPress database | `wordpress_db` |

## Troubleshooting

```bash
# Logs opérateur
kubectl logs -n mysql-operator deployment/mysql-operator -f

# Logs d'un pod MySQL
kubectl logs -n wordpress-ha mycluster-0 -c mysql --tail=50

# Logs MySQLRouter
kubectl logs -n wordpress-ha -l component=mysqlrouter --tail=50

# Décrire le cluster (events, erreurs)
kubectl describe innodbcluster mycluster -n wordpress-ha

# Événements namespace
kubectl get events -n wordpress-ha --sort-by='.lastTimestamp'
```
