Voici la séquence d'instructions optimisée pour ta stack HA, en intégrant le stockage répliqué avec Longhorn, le mode Multi-Disk pour MinIO sur 3 nœuds, et la gestion ReadWriteMany (RWX) pour le code source de WordPress.
Séquence de Mise en Œuvre HA (1M + 2W)
Phase A : La Fondation (Stockage Répliqué)
C'est ici que tu élimines le besoin de ton serveur NFS actuel pour la base de données.

1. Préparation des nœuds : Sur le Master et les 2 Workers : `sudo apt install open-iscsi nfs-common -y`.
2. Installation de Longhorn : * Installer via Helm dans le namespace `longhorn-system`.
   * Configurer le `defaultClassReplicaCount: 3`.
3. Activation du mode RWX : Longhorn propose nativement le support ReadWriteMany en lançant un petit pod proxy NFS interne. C'est ce que nous utiliserons pour le code source PHP de WordPress.
Phase B : Les Services de Données (HA & Quorum)
On déploie les moteurs qui nécessitent une cohérence forte.

1. MariaDB Galera :
   * Utiliser la StorageClass `longhorn`.
   * Configurer l'Anti-Affinité (1 instance par nœud physique).
   * Vérifier que le cluster est "Ready" ($wsrep\_cluster\_size = 3$).
2. Redis Sentinel :
   * Déploiement de 3 pods (1 Master + 2 Replicas) + 3 Sentinelles.
   * Utiliser Longhorn pour la persistance du Master/Replicas.
Phase C : MinIO (Stockage Objet à 6 disques)
Pour activer l'Erasure Coding sur seulement 3 nœuds physiques :

1. Installation du MinIO Operator : C'est la méthode la plus propre pour gérer des "Tenants".
2. Configuration des disques :
   * Lors de la création du Tenant, configure 2 volumes (PVC) par nœud.
   * Demande à Longhorn de fournir ces 6 volumes (2 par nœud x 3 nœuds).
   * MinIO verra 6 "disques" et pourra ainsi activer la protection par répartition de données (Erasure Coding), permettant de perdre jusqu'à 2 disques (ou 1 nœud complet) sans perte de données.
Phase D : WordPress HA Stateless & RWX
C'est ici que tout s'assemble.

1. Configuration du Volume RWX :
   * Créer une PVC avec `accessModes: [ReadWriteMany]` utilisant la StorageClass `longhorn`.
   * Ce volume sera monté sur `/var/www/html` de tous tes pods WordPress. Ainsi, une mise à jour d'un plugin sur un pod est immédiatement visible sur les autres.
2. Déploiement WordPress :
   * Configurer `replicas: 3`.
   * Lier WordPress au service `mariadb-galera` et au cluster `redis-sentinel`.
3. Liaison Médias (S3) :
   * Installer et configurer le plugin WP Offload Media (ou similaire).
   * Pointer vers l'URL interne de ton MinIO Tenant (ex: `http://minio.minio-tenant.svc.cluster.local`).
   * Désormais, chaque image uploadée part dans le cluster MinIO à 6 disques et n'alourdit pas le volume PHP.

Résumé Technique de la Stack
ComposantMode de RésilienceType de StockageCode PHPRéplication Pods (x3)Longhorn RWX (NFS partagé)Base de donnéesMariaDB Galera (Synchrone)Longhorn RWO (Block natif)CacheRedis Sentinel (Failover auto)Longhorn RWOMédias/ImagesMinIO (Erasure Coding 6 disques)Longhorn RWO (x6 volumes)

Voici la séquence d'instructions optimisée pour ta stack HA, en intégrant le stockage répliqué avec Longhorn, le mode Multi-Disk pour MinIO sur 3 nœuds, et la gestion ReadWriteMany (RWX) pour le code source de WordPress.
Séquence de Mise en Œuvre HA (1M + 2W)
Phase A : La Fondation (Stockage Répliqué)
C'est ici que tu élimines le besoin de ton serveur NFS actuel pour la base de données.

1. Préparation des nœuds : Sur le Master et les 2 Workers : `sudo apt install open-iscsi nfs-common -y`.
2. Installation de Longhorn : * Installer via Helm dans le namespace `longhorn-system`.
   * Configurer le `defaultClassReplicaCount: 3`.
3. Activation du mode RWX : Longhorn propose nativement le support ReadWriteMany en lançant un petit pod proxy NFS interne. C'est ce que nous utiliserons pour le code source PHP de WordPress.

kubectl get nodes -n longhorn-system
# Vérifier que tous les nœuds ont le statut "schedulable: true"
kubectl get storageclass longhorn

Phase B : Les Services de Données (HA & Quorum)
On déploie les moteurs qui nécessitent une cohérence forte.

1. MariaDB Galera :
   * Utiliser la StorageClass `longhorn`.
   * Configurer l'Anti-Affinité (1 instance par nœud physique).
   * Vérifier que le cluster est "Ready" ($wsrep\_cluster\_size = 3$).
2. Redis Sentinel :
   * Déploiement de 3 pods (1 Master + 2 Replicas) + 3 Sentinelles.
   * Utiliser Longhorn pour la persistance du Master/Replicas.
Phase C : MinIO (Stockage Objet à 6 disques)
Pour activer l'Erasure Coding sur seulement 3 nœuds physiques :

1. Installation du MinIO Operator : C'est la méthode la plus propre pour gérer des "Tenants".
2. Configuration des disques :
   * Lors de la création du Tenant, configure 2 volumes (PVC) par nœud.
   * Demande à Longhorn de fournir ces 6 volumes (2 par nœud x 3 nœuds).
   * MinIO verra 6 "disques" et pourra ainsi activer la protection par répartition de données (Erasure Coding), permettant de perdre jusqu'à 2 disques (ou 1 nœud complet) sans perte de données.
Phase D : WordPress HA Stateless & RWX
C'est ici que tout s'assemble.

1. Configuration du Volume RWX :
   * Créer une PVC avec `accessModes: [ReadWriteMany]` utilisant la StorageClass `longhorn`.
   * Ce volume sera monté sur `/var/www/html` de tous tes pods WordPress. Ainsi, une mise à jour d'un plugin sur un pod est immédiatement visible sur les autres.
2. Déploiement WordPress :
   * Configurer `replicas: 3`.
   * Lier WordPress au service `mariadb-galera` et au cluster `redis-sentinel`.
3. Liaison Médias (S3) :
   * Installer et configurer le plugin WP Offload Media (ou similaire).
   * Pointer vers l'URL interne de ton MinIO Tenant (ex: `http://minio.minio-tenant.svc.cluster.local`).
   * Désormais, chaque image uploadée part dans le cluster MinIO à 6 disques et n'alourdit pas le volume PHP.
Résumé Technique de la Stack
Composant               Mode de Résilience                                   Type de Stockage
Code PHP                   Réplication Pods (x3)                               Longhorn RWX (NFS partagé)
Base de données    MariaDB Galera (Synchrone)              Longhorn RWO (Block natif)
Cache                           Redis Sentinel (Failover auto)             Longhorn RWO
Médias/Images        MinIO (Erasure Coding 6 disques)   Longhorn RWO (x6 volumes)

Le Test Ultime (Chaos Engineering)
Pour valider ton tutoriel vidéo, effectue ce test :

1. Éteins brutalement un des deux Workers.
2. Observe Kubernetes qui détecte la panne.
3. Vérifie que WordPress continue de répondre (grâce aux réplicas sur le Master et l'autre Worker).
4. Vérifie que MariaDB accepte toujours les écritures (Quorum 2/3 maintenu).
Cette séquence est la plus proche d'une architecture de production "Enterprise" que tu puisses réaliser sur un cluster de 3 nœuds.

---

_En Phase D — préciser l'init du volume RWX :
Le premier pod WordPress qui démarre sur un volume RWX vide doit copier les fichiers WordPress dedans. Avec une image officielle wordpress:php8.2-apache, ce n'est pas automatique si le volume existe déjà vide. Un initContainer ou un Job d'initialisation est nécessaire.
Ingress + TLS — tu as mentionné Phase E différée dans ta stack précédente. Pour la vidéo, un NodePort suffit pour le chaos test, mais précise-le explicitement pour éviter les questions en commentaires._
