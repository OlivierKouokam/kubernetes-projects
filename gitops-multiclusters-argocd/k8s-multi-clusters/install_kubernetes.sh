#!/bin/bash
# 1. Mettre à jour la liste des paquets et appliquer les mises à jour disponibles
sudo apt update

# 2. Activer le dépôt Universe et le PPA officiel d'Ansible
sudo apt -y install software-properties-common
sudo add-apt-repository universe
sudo add-apt-repository --yes ppa:ansible/ansible
sudo apt update

# 3. Installer Ansible
sudo apt -y install ansible

# 4. Installer Git
sudo apt -y install git

# 5. Nettoyer un éventuel répertoire existant
rm -rf kubernetes-certification-stack || echo "previous folder removed"

# Récupération du dépôt Eazytraining
git clone -b feat/ubuntu https://github.com/eazytraining/kubernetes-certification-stack.git
cd kubernetes-certification-stack
KUBERNETES_VERSION=1.31
ansible-galaxy install -r roles/requirements.yml

# Execution du rôle en mode master / control_plane autonome
if [ "$1" == "master" ]
then
        ansible-playbook install_kubernetes.yml --extra-vars "kubernetes_role=control_plane kubernetes_apiserver_advertise_address=$2 installation_method=vagrant kubernetes_version='$KUBERNETES_VERSION'"
        
        # Installer bash-completion puis enregistrer l’auto-complétion de kubectl
        sudo apt update && sudo apt -y install bash-completion \
        && kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
        echo 'source <(kubectl completion bash)' >> ~/.bashrc

        echo "###################################################"
        echo " Cluster $(hostname) initialisé avec succès !"
        echo " Adresse IP de l'API Server : $2"
        echo " Exécutez 'sudo su -' pour utiliser kubectl sur cette VM"
        echo "###################################################"
fi
