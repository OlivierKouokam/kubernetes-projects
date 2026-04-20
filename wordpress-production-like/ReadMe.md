# WordPress HA Stack — Kubernetes 1M+2W avec Longhorn

> **Cluster cible :** 1 Master (schedulable) + 2 Workers — kubeadm — Vagrant/VirtualBox

---

## Dimensionnement des VMs

| Paramètre | Valeur |
|---|---|
| Nœuds | 3 (master schedulable + worker1 + worker2) |
| vCPU / nœud | 4 |
| RAM / nœud | 8 Go |
| Disque OS / nœud | ~25 Go (box Ubuntu Jammy) |
| Disque Longhorn / nœud | 50 Go (`/dev/sdb` dédié) |
| Total RAM alloué | 24 Go / 64 Go |
| Total vCPU alloué | 12 threads / 12 threads logiques |
| Réseau | Host-only `192.168.56.0/24` |

> ⚠️ **VirtualBox gère bien l'overcommit léger.** Les 12 threads alloués correspondent aux 12 threads logiques du i7-10850H (6C/12T). L'hôte Windows conserve suffisamment de ressources grâce aux 40 Go RAM restants.

---

## Vagrantfile — Configuration recommandée

Chaque VM dispose de **deux disques** : le disque OS géré par la box, et un disque VDI dédié à Longhorn.

```ruby
Vagrant.configure("2") do |config|
  [
    { name: "master",  ip: "192.168.56.10" },
    { name: "worker1", ip: "192.168.56.11" },
    { name: "worker2", ip: "192.168.56.12" }
  ].each do |node|
    config.vm.define node[:name] do |n|
      n.vm.box      = "ubuntu/jammy64"
      n.vm.hostname = node[:name]
      n.vm.network "private_network", ip: node[:ip]

      n.vm.provider "virtualbox" do |vb|
        vb.name   = node[:name]
        vb.cpus   = 4
        vb.memory = 8192

        # Disque dédié Longhorn (50 Go)
        disk_path = "#{ENV['HOME']}/vbox-disks/#{node[:name]}-longhorn.vdi"
        unless File.exist?(disk_path)
          vb.customize ["createhd",
            "--filename", disk_path,
            "--size",     51200]
        end
        vb.customize ["storageattach", :id,
          "--storagectl", "SCSI",
          "--port",        2,
          "--device",      0,
          "--type",        "hdd",
          "--medium",      disk_path]
      end
    end
  end
end
```

> 💡 Le dossier `~/vbox-disks/` doit exister avant le premier `vagrant up`. Créer manuellement si nécessaire.

---

## Retrait du taint master (post-kubeadm init)

Par défaut, kubeadm pose un taint `NoSchedule` sur le master. Le retirer pour permettre le scheduling des workloads :

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

> ⚠️ Ce taint est nécessaire pour le quorum Galera (3 instances sur 3 nœuds distincts) et l'Erasure Coding MinIO (3 nœuds physiques requis).

---

## Phase A — La Fondation : Stockage Répliqué (Longhorn)

> **Objectif :** Éliminer le serveur NFS externe. Tout le stockage persistant sera fourni par Longhorn avec réplication triple.

### A.1 — Préparation des nœuds (sur les 3 nœuds)

```bash
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

> 💡 `open-iscsi` est requis par Longhorn pour le stockage bloc. `nfs-common` est requis pour le mode RWX.

### A.2 — Installation de Longhorn via Helm

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath="/var/lib/longhorn" \
  --set defaultSettings.defaultReplicaCount=3
```

> ⚠️ Avant l'installation, formater et monter `/dev/sdb` sur chaque nœud :
> ```bash
> sudo mkfs.ext4 /dev/sdb
> sudo mkdir -p /var/lib/longhorn
> echo '/dev/sdb /var/lib/longhorn ext4 defaults 0 0' | sudo tee -a /etc/fstab
> sudo mount -a
> ```

### A.3 — Activation du mode RWX

Le support ReadWriteMany est natif dans Longhorn. Il fonctionne en déployant automatiquement un **pod proxy NFS interne** (`share-manager`) pour chaque PVC RWX.

```bash
# Vérifier que le feature gate RWX est actif (activé par défaut depuis Longhorn 1.3)
kubectl get settings -n longhorn-system rwx-volume-fast-failover
```

> ℹ️ **Point de vigilance :** Le pod `share-manager` est un point de concentration par volume RWX. Longhorn le redémarre automatiquement en cas de panne du nœud qui l'héberge (~30-60s de failover). Pour du code PHP WordPress en lecture quasi-constante, cette latence est acceptable.

### A.4 — Validation Longhorn (étape obligatoire avant Phase B)

```bash
# Tous les nœuds doivent être "schedulable: true"
kubectl get nodes -n longhorn-system

# La StorageClass longhorn doit être présente
kubectl get storageclass longhorn

# Vérifier l'UI Longhorn (optionnel, port-forward)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

---

## Phase B — Les Services de Données (HA & Quorum)

> **Objectif :** Déployer les moteurs de données qui nécessitent une cohérence forte et un quorum.

### B.1 — MariaDB Galera

**Chart :** `bitnami/mariadb-galera`

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami

helm install mariadb-galera bitnami/mariadb-galera \
  --namespace wordpress \
  --create-namespace \
  --set rootUser.password=<ROOT_PASSWORD> \
  --set db.user=wordpress \
  --set db.password=<WP_DB_PASSWORD> \
  --set db.name=wordpress \
  --set replicaCount=3 \
  --set persistence.storageClass=longhorn \
  --set persistence.size=10Gi \
  --set podAntiAffinity=hard
```

**Anti-affinité (1 instance par nœud physique) :** à inclure dans les values si le chart ne l'expose pas directement :

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: mariadb-galera
        topologyKey: kubernetes.io/hostname
```

**Validation :**

```bash
kubectl exec -it mariadb-galera-0 -n wordpress -- \
  mysql -uroot -p<ROOT_PASSWORD> -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Résultat attendu : wsrep_cluster_size = 3
```

> ⚠️ **Piège classique — Bootstrap Galera :**
> Le premier démarrage nécessite `galera.bootstrap.bootstrapFromNode=0` (géré automatiquement par le chart Bitnami).
> En cas de **redémarrage complet du cluster** (tous les pods down simultanément), les pods Galera démarrent en cherchant un pair actif → **deadlock garanti**.
>
> **Procédure de recovery :**
> ```bash
> # Identifier le nœud avec le GTID le plus récent
> kubectl exec -it mariadb-galera-0 -n wordpress -- \
>   cat /var/lib/mysql/grastate.dat
> # Sur le nœud avec safe_to_bootstrap: 1
> helm upgrade mariadb-galera bitnami/mariadb-galera \
>   --set galera.bootstrap.bootstrapFromNode=0 \
>   --set galera.bootstrap.forceSafeToBootstrap=true
> ```
>
> **Documenter cette procédure dans le README du projet** — elle est indispensable pour le lab.

> ℹ️ **Galera vs MySQL InnoDB Cluster :**
> Galera utilise une réplication **synchrone multi-master** (tous les nœuds acceptent les écritures). WordPress est compatible MariaDB et ce mode est bien adapté. Si tu as utilisé MySQL Operator dans une stack précédente, note que Galera gère différemment les cas de split-brain — à mentionner dans la vidéo.

### B.2 — Redis Sentinel

**Chart :** `bitnami/redis`

```bash
helm install redis bitnami/redis \
  --namespace wordpress \
  --set architecture=replication \
  --set auth.password=<REDIS_PASSWORD> \
  --set sentinel.enabled=true \
  --set sentinel.quorum=2 \
  --set replica.replicaCount=2 \
  --set master.persistence.storageClass=longhorn \
  --set master.persistence.size=2Gi \
  --set replica.persistence.storageClass=longhorn \
  --set replica.persistence.size=2Gi
```

> **Résultat :** 1 Master + 2 Replicas + 3 Sentinelles (quorum = 2).
> En cas de panne du Master, les 3 Sentinelles votent et élisent un nouveau Master automatiquement.

---

## Phase C — MinIO (Stockage Objet Erasure Coding à 6 disques)

> **Objectif :** Fournir un stockage objet S3-compatible résilient sur 3 nœuds physiques avec Erasure Coding.

### C.1 — Installation du MinIO Operator

```bash
helm repo add minio-operator https://operator.min.io

helm install minio-operator minio-operator/operator \
  --namespace minio-operator \
  --create-namespace
```

### C.2 — Création du Tenant (2 volumes par nœud × 3 nœuds = 6 disques)

```yaml
# minio-tenant.yaml
apiVersion: minio.min.io/v2
kind: Tenant
metadata:
  name: minio-tenant
  namespace: minio-tenant
spec:
  pools:
    - servers: 3
      volumesPerServer: 2          # 2 PVC par pod MinIO = 6 disques total
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 20Gi        # 20 Go × 6 = 120 Go bruts
  requestAutoCert: false
```

```bash
kubectl create namespace minio-tenant
kubectl apply -f minio-tenant.yaml
```

> ℹ️ **Pourquoi 6 disques ?**
> MinIO Erasure Coding nécessite un minimum de 4 disques pour s'activer. Avec 6 disques (`EC:3`), MinIO peut perdre jusqu'à **3 disques** — soit **1 nœud complet** — sans perte de données ni interruption de service.
>
> ⚠️ Longhorn fournit ces 6 PVC RWO en stockage bloc natif. L'Erasure Coding MinIO opère **par-dessus** Longhorn — les deux couches de réplication sont indépendantes. Pour un lab, cette double réplication est intentionnelle (démo de production).

---

## Phase D — WordPress HA Stateless & RWX

> **Objectif :** Déployer WordPress en mode stateless avec 3 réplicas partageant le même volume PHP via RWX.

### D.1 — PVC ReadWriteMany pour le code PHP

```yaml
# wordpress-rwx-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wordpress-php-rwx
  namespace: wordpress
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl apply -f wordpress-rwx-pvc.yaml
```

> ℹ️ Ce volume est monté sur `/var/www/html` de **tous les pods WordPress simultanément**. Une mise à jour de plugin effectuée depuis n'importe quel pod est immédiatement visible sur les autres.

### D.2 — Initialisation du volume RWX (étape critique)

> ⚠️ **Piège fréquent :** L'image officielle `wordpress:php8.2-apache` ne copie pas les fichiers WordPress si le volume cible existe déjà (même vide). Il faut un **initContainer** pour peupler le volume au premier démarrage :

```yaml
initContainers:
  - name: init-wordpress-files
    image: wordpress:php8.2-apache
    command:
      - sh
      - -c
      - |
        if [ ! -f /var/www/html/wp-login.php ]; then
          cp -r /usr/src/wordpress/. /var/www/html/
          chown -R www-data:www-data /var/www/html/
        fi
    volumeMounts:
      - name: wordpress-php
        mountPath: /var/www/html
```

### D.3 — Déploiement WordPress

```bash
helm install wordpress bitnami/wordpress \
  --namespace wordpress \
  --set replicaCount=3 \
  --set mariadb.enabled=false \
  --set externalDatabase.host=mariadb-galera \
  --set externalDatabase.user=wordpress \
  --set externalDatabase.password=<WP_DB_PASSWORD> \
  --set externalDatabase.database=wordpress \
  --set redis.enabled=false \
  --set wordpressExtraEnvVars[0].name=WP_REDIS_HOST \
  --set wordpressExtraEnvVars[0].value=redis \
  --set persistence.existingClaim=wordpress-php-rwx \
  --set service.type=NodePort
```

> ℹ️ **NodePort pour la démo vidéo** — Phase E (Ingress + TLS) est volontairement différée. L'URL d'accès sera `http://<IP_MASTER>:<NODE_PORT>`. Préciser ce point dans la vidéo pour éviter les questions en commentaires.

### D.4 — Liaison Médias vers MinIO (WP Offload Media)

Depuis le tableau de bord WordPress :

1. Installer le plugin **WP Offload Media Lite** (ou version payante)
2. Configurer le provider S3 avec l'URL interne MinIO :
   - **Endpoint :** `http://minio-tenant.minio-tenant.svc.cluster.local`
   - **Bucket :** `wordpress-media`
   - **Access Key / Secret Key :** récupérés depuis le Secret du Tenant MinIO

```bash
# Récupérer les credentials MinIO
kubectl get secret minio-tenant-env-configuration \
  -n minio-tenant -o jsonpath='{.data.config\.env}' | base64 -d
```

> Chaque image uploadée part dans le cluster MinIO à 6 disques et n'alourdit pas le volume PHP RWX.

---

## Résumé de la Stack

| Composant | Mode de Résilience | Type de Stockage |
|---|---|---|
| Code PHP | Réplication Pods (×3) | Longhorn RWX (NFS interne) |
| Base de données | MariaDB Galera — synchrone | Longhorn RWO — bloc natif |
| Cache | Redis Sentinel — failover auto | Longhorn RWO |
| Médias / Images | MinIO Erasure Coding (6 disques) | Longhorn RWO (×6 volumes) |

---

## Le Test Ultime — Chaos Engineering

> **Objectif vidéo :** Démontrer qu'aucun composant ne tombe lors de la perte d'un nœud.

### Procédure

```bash
# Terminal 1 — Surveillance continue
watch -n 2 kubectl get pods -n wordpress -o wide

# Terminal 2 — Test de disponibilité WordPress
while true; do
  curl -s -o /dev/null -w "%{http_code}" http://192.168.56.10:<NODE_PORT>
  echo " — $(date +%H:%M:%S)"
  sleep 2
done

# Terminal 3 — Surveillance Galera
watch -n 2 'kubectl exec -it mariadb-galera-0 -n wordpress -- \
  mysql -uroot -p<ROOT_PASSWORD> -e "SHOW STATUS LIKE '"'"'wsrep%'"'"';" 2>/dev/null'
```

### Extinction d'un Worker

```bash
# Depuis l'hôte Windows
vagrant halt worker1
```

### Observations attendues

1. Kubernetes détecte la panne (~40s — `NodeNotReady`)
2. Les pods du nœud éteint sont recréés sur les 2 nœuds restants
3. WordPress continue de répondre HTTP 200 (réplicas sur master + worker2)
4. Galera maintient le quorum 2/3 — les écritures continuent
5. MinIO maintient le service — Erasure Coding tolère la perte d'1 nœud (`EC:3`)

### Redémarrage du nœud

```bash
vagrant up worker1
# Galera re-synchronise automatiquement via SST/IST
# Longhorn re-réplique les volumes vers le nœud revenu
```

> 💡 **Pour la vidéo :** montrer les 3 terminaux en split-screen pendant l'extinction. La continuité du HTTP 200 est l'élément le plus percutant visuellement.

---

## Checklist de Déploiement

- [ ] `vagrant up` — 3 VMs démarrées
- [ ] kubeadm init + join workers
- [ ] Retrait du taint master (`control-plane-`)
- [ ] `/dev/sdb` formaté et monté sur `/var/lib/longhorn` (3 nœuds)
- [ ] Longhorn installé — tous les nœuds `schedulable: true`
- [ ] StorageClass `longhorn` présente et définie comme default
- [ ] MariaDB Galera — `wsrep_cluster_size = 3`
- [ ] Redis Sentinel — 3 sentinelles `+monitor master`
- [ ] MinIO Tenant — 6 PVC `Bound`, Erasure Coding actif
- [ ] PVC RWX `wordpress-php-rwx` — status `Bound`
- [ ] WordPress — 3 pods `Running`, `readinessProbe` OK
- [ ] WP Offload Media configuré vers MinIO
- [ ] Chaos test validé
