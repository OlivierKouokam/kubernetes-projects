# MySQL HA Stack — Guide de déploiement par couche
# ====================================================
# Cluster K8s v1.34 — 1 Master + 1 Worker

## Structure des fichiers

    mysql-ha/
    ├── 00-namespace/
    │   └── namespace.yaml              # Namespace "wordpress"
    ├── 01-storage/
    │   └── storageclass.yaml           # StorageClass NFS (nfs-mysql)
    ├── 02-mysql/
    │   ├── 01-secret.yaml              # Credentials (à modifier !)
    │   ├── 02-configmap-mycnf.yaml     # my.cnf avec MGR activé
    │   ├── 03-configmap-scripts.yaml   # Scripts bash (init/bootstrap/monitor)
    │   ├── 04-headless-service.yaml    # Service headless (DNS pod-by-pod)
    │   └── 05-statefulset.yaml         # StatefulSet MySQL (3 pods)
    ├── 03-proxysql/
    │   ├── 01-configmap-proxysql.yaml  # proxysql.cnf
    │   ├── 02-configmap-configurator.yaml  # Script Python sync dynamique
    │   └── 03-deployment.yaml          # Deployment ProxySQL + sidecar
    ├── 04-services/
    │   └── services.yaml               # ClusterIP proxysql-svc (point d'entrée)
    └── 05-network-policies/
        └── network-policies.yaml       # Isolation réseau (deny-all + allow list)


## AVANT de déployer

### 1. Modifier les passwords dans le Secret
    vi mysql-ha/02-mysql/01-secret.yaml
    # Générer vos valeurs :
    echo -n "VotreMotDePasse" | base64

### 2. Adapter la StorageClass à votre NFS
    vi mysql-ha/01-storage/storageclass.yaml
    # Vérifier le nom du provisioner :
    kubectl get pods -n nfs-provisioner


## Déploiement par couche

### Couche 0 — Namespace
    kubectl apply -f mysql-ha/00-namespace/

### Couche 1 — Storage
    kubectl apply -f mysql-ha/01-storage/
    kubectl get storageclass nfs-mysql

### Couche 2 — MySQL
    kubectl apply -f mysql-ha/02-mysql/
    # Attendre que les pods démarrent (peut prendre 2-5 min)
    kubectl get pods -n wordpress -w

### Couche 3 — ProxySQL
    kubectl apply -f mysql-ha/03-proxysql/
    kubectl get pods -n wordpress -l app=proxysql -w

### Couche 4 — Services
    kubectl apply -f mysql-ha/04-services/

### Couche 5 — Network Policies
    kubectl apply -f mysql-ha/05-network-policies/


## Vérifications

### Vérifier l'état des pods
    kubectl get pods -n wordpress -o wide

### Vérifier les logs d'initialisation MySQL
    kubectl logs -n wordpress mysql-0 -c mgr-bootstrap
    kubectl logs -n wordpress mysql-1 -c mgr-bootstrap

### Vérifier la topologie MGR
    kubectl exec -n wordpress mysql-0 -c mysql -- \
      mysql -uroot -prootpassword -h127.0.0.1 -e "
        SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE
        FROM performance_schema.replication_group_members;
      "

### Vérifier la config ProxySQL
    PROXYSQL_POD=$(kubectl get pod -n wordpress -l app=proxysql -o jsonpath='{.items[0].metadata.name}')

    kubectl exec -n wordpress ${PROXYSQL_POD} -c proxysql -- \
      mysql -uadmin -pproxyadmin123 -h127.0.0.1 -P6032 -e "
        SELECT hostgroup_id, hostname, port, status, weight
        FROM runtime_mysql_servers;
      "

### Logs du configurateur Python
    kubectl logs -n wordpress ${PROXYSQL_POD} -c proxysql-configurator -f


## Scale up (ajouter un replica)

    # 1. Scaler le StatefulSet
    kubectl scale statefulset mysql --replicas=4 -n wordpress

    # 2. Mettre à jour REPLICAS dans le ConfigMap ProxySQL
    kubectl set env deployment/proxysql -n wordpress \
      -c proxysql-configurator REPLICAS=4

    # Le configurateur Python détectera mysql-3 dans MGR
    # et l'ajoutera automatiquement au pool de lecture.

    # Vérifier
    kubectl get pods -n wordpress -l app=mysql
    kubectl exec -n wordpress ${PROXYSQL_POD} -c proxysql -- \
      mysql -uadmin -pproxyadmin123 -h127.0.0.1 -P6032 -e "
        SELECT * FROM runtime_mysql_servers;
      "


## Test de failover

    # Simuler la perte du primary (mysql-0)
    kubectl delete pod mysql-0 -n wordpress

    # Observer l'élection du nouveau primary
    kubectl logs -n wordpress ${PROXYSQL_POD} -c proxysql-configurator -f

    # Vérifier que ProxySQL a bien reconfiguré le writer
    kubectl exec -n wordpress ${PROXYSQL_POD} -c proxysql -- \
      mysql -uadmin -pproxyadmin123 -h127.0.0.1 -P6032 -e "
        SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers;
      "
