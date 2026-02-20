FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Installer les dépendances système
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        apt-transport-https \
        git \
        sudo \
        iproute2 \
        conntrack \
        docker.io && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Installer Docker (DinD)
RUN curl -fsSL https://get.docker.com | sh

# Installer kubectl
RUN curl -LO "https://dl.k8s.io/release/v1.34.4/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/

# Installer kind
RUN curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64 && \
    chmod +x kind && mv kind /usr/local/bin/kind

# Copier le cluster pré-configuré
COPY kind-cluster /kind-cluster

# Copier le script de démarrage rapide
COPY start_kind.sh /usr/local/bin/start_kind.sh
RUN chmod +x /usr/local/bin/start_kind.sh

# Entrée par défaut
CMD ["/usr/local/bin/start_kind.sh"]
