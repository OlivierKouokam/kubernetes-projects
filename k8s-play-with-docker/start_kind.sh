#!/bin/bash
set -e

export KUBECONFIG=/kind-cluster/kubeconfig

if ! kind get clusters | grep -q mycluster; then
    echo "KinD Cluster Creation..."
    kind create cluster --name eazy-cluster --config /kind-cluster/kind-config.yaml --kubeconfig /kind-cluster/kubeconfig

    echo "Attente API server..."
    until kubectl cluster-info >/dev/null 2>&1; do
        sleep 2
    done

    echo "Attente Node Ready..."
    kubectl wait --for=condition=Ready node --all --timeout=120s

    echo "Cluster Kubernetes-In-Docker started."
    echo "Enter 'kubectl get node' to make sure the node is Ready !!!"
else
    echo "Cluster already exists."
fi

tail -f /dev/null
