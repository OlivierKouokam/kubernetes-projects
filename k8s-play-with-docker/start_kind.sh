#!/bin/bash
set -e

export KUBECONFIG=/kind-cluster/kubeconfig

if ! kind get clusters | grep -q mycluster; then

    RANDOM_NAME="kind-$(head /dev/urandom | tr -dc a-z0-9 | head -c6)"

    echo "KinD Cluster Creation..."
    #kind create cluster --name $RANDOM_NAME --config /kind-cluster/kind-config.yaml --kubeconfig /kind-cluster/kubeconfig
    kind create cluster --name $RANDOM_NAME --kubeconfig /kind-cluster/kubeconfig
    echo "Attente API server..."
    until kubectl cluster-info >/dev/null 2>&1; do
        sleep 2
    done
    
    echo "Attente Node Ready..."
    kubectl wait --for=condition=Ready node --all --timeout=120s
    echo
    echo "+++++++++++++++++++++++++++++++++++++"
    echo "Cluster Kubernetes-In-Docker started."
    echo "Cluster name: $RANDOM_NAME"
    echo "+++++++++++++++++++++++++++++++++++++"
    echo
    echo "-----------------------------------------------------------"
    echo "Enter 'kubectl get node' to make sure the node is Ready !!!"
    echo "-----------------------------------------------------------"
    echo
else
    echo "Cluster already exists."
fi

tail -f /dev/null
