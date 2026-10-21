#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# CONFIGURATION
################################################################################

BASE_DIR="$(pwd)"
TMP_DIR="$(mktemp -d)"

REPOS=(
    "2SCloud/scloud-dns|scloud-dns"
    "2SCloud/scloud-observability|scloud-observability"
)

################################################################################
# LOGGING
################################################################################

log_info() {
    echo "[INFO ] $*"
}

log_warn() {
    echo "[WARN ] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

################################################################################
# DEPENDANCES
################################################################################

install_package() {

    local pkg="$1"

    if command -v apt-get >/dev/null 2>&1; then

        sudo apt-get update -qq
        sudo apt-get install -y "$pkg"

    elif command -v dnf >/dev/null 2>&1; then

        sudo dnf install -y "$pkg"

    elif command -v yum >/dev/null 2>&1; then

        sudo yum install -y "$pkg"

    elif command -v zypper >/dev/null 2>&1; then

        sudo zypper install -y "$pkg"

    elif command -v pacman >/dev/null 2>&1; then

        sudo pacman -Sy --noconfirm "$pkg"

    elif command -v apk >/dev/null 2>&1; then

        sudo apk add "$pkg"

    else

        log_error "Gestionnaire de paquets non supporté."
        exit 1

    fi
}

install_helm() {

    if command -v helm >/dev/null 2>&1; then
        log_info "Helm déjà installé."
        return 0
    fi

    log_info "Installation de Helm depuis GitHub..."

    local version
    version=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')

    cd "$TMP_DIR"

    curl -L -o helm.tar.gz \
        "https://get.helm.sh/helm-${version}-linux-amd64.tar.gz"

    tar -xzf helm.tar.gz

    sudo install -m 755 linux-amd64/helm /usr/local/bin/helm

    helm version --short
}

install_k3s() {

    if kubectl cluster-info >/dev/null 2>&1; then
        log_info "Cluster Kubernetes déjà accessible."
        return
    fi

    log_info "Aucun cluster détecté. Installation de k3s..."

    curl -sfL https://get.k3s.io | sh -

    mkdir -p "$HOME/.kube"

    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"

    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

    export KUBECONFIG="$HOME/.kube/config"

    log_info "Attente du démarrage de k3s..."

    for i in {1..30}
    do
        if kubectl get nodes >/dev/null 2>&1; then
            log_info "Cluster Kubernetes prêt."
            return
        fi

        sleep 2
    done

    log_error "Le cluster k3s ne répond pas."
    exit 1
}

install_kubectl() {

    if command -v kubectl >/dev/null 2>&1; then
        log_info "kubectl déjà installé : $(kubectl version --client --short 2>/dev/null || echo OK)"
        return 0
    fi

    log_info "kubectl n'est pas installé. Installation..."

    local version
    version=$(curl -fsSL https://dl.k8s.io/release/stable.txt)

    curl -fsSL \
        -o "${TMP_DIR}/kubectl" \
        "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"

    chmod +x "${TMP_DIR}/kubectl"

    sudo install -m 0755 \
        "${TMP_DIR}/kubectl" \
        /usr/local/bin/kubectl

    if command -v kubectl >/dev/null 2>&1; then
        log_info "kubectl installé : $(kubectl version --client --short 2>/dev/null || echo OK)"
    else
        log_error "Échec de l'installation de kubectl."
        exit 1
    fi
}

check_dependencies() {

    declare -A packages=(
        [curl]="curl"
        [jq]="jq"
        [tar]="tar"
    )

    for cmd in "${!packages[@]}"
    do
        if ! command -v "$cmd" >/dev/null 2>&1; then

            log_info "Installation de $cmd"

            install_package "${packages[$cmd]}"
        fi
    done

    install_helm
    install_kubectl
    log_info "Toutes les dépendances sont installées."
}

################################################################################
# GITHUB
################################################################################

get_latest_tag() {

    local repo="$1"

    curl -fsSL \
        "https://api.github.com/repos/${repo}/releases/latest" |
        jq -r '.tag_name'
}

################################################################################
# INSTALLATION
################################################################################

install_release() {

    local repo="$1"
    local folder="$2"

    log_info "Téléchargement de ${repo}"

    local tag

    tag=$(get_latest_tag "$repo")

    if [[ -z "$tag" || "$tag" == "null" ]]; then

        log_error "Release introuvable pour ${repo}"
        return 1

    fi

    log_info "Release détectée : ${tag}"

    local archive_file
    archive_file="${TMP_DIR}/${folder}.tar.gz"

    local archive_url
    archive_url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"

    curl -L \
        "$archive_url" \
        -o "$archive_file"

    mkdir -p "${BASE_DIR}/${folder}"

    tar -xzf \
        "$archive_file" \
        -C "${BASE_DIR}/${folder}" \
        --strip-components=1

    log_info "Sources extraites dans ${BASE_DIR}/${folder}"
}

################################################################################
# GRAFANA ACCESS
################################################################################

configure_grafana_ingress_dns() {

    local HOSTNAME="observability.scloud.moe"

    log_info "Configuration DNS local ${HOSTNAME}..."

    local IP

    IP=$(kubectl get nodes \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    if grep -qi microsoft /proc/version 2>/dev/null; then

        log_info "WSL détecté"

        if powershell.exe -Command "
\$hosts='C:\Windows\System32\drivers\etc\hosts'

if (Test-Path \$hosts) {

    \$content = Get-Content \$hosts -ErrorAction SilentlyContinue

    \$newContent = \$content | Where-Object { \$_ -notmatch '${HOSTNAME}' }

    Set-Content -Path \$hosts -Value \$newContent

    Add-Content -Path \$hosts -Value '${IP} ${HOSTNAME}'
}
" >/dev/null 2>&1; then

            log_info "Entrée hosts Windows configurée."

        else

            log_warn "Impossible de modifier automatiquement le fichier hosts Windows."

            echo
            log_warn "Ouvrez PowerShell en Administrateur puis exécutez :"
            echo
            echo "Add-Content C:\Windows\System32\drivers\etc\hosts '${IP} ${HOSTNAME}'"
            echo
        fi

    elif [[ "$OSTYPE" == "darwin"* ]]; then

        if grep -q "${HOSTNAME}" /etc/hosts 2>/dev/null; then

            sudo sed -i '' "/${HOSTNAME}/d" /etc/hosts
        fi

        echo "${IP} ${HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null

        log_info "Entrée hosts macOS configurée."

    else

        if grep -q "${HOSTNAME}" /etc/hosts 2>/dev/null; then

            sudo sed -i "/${HOSTNAME}/d" /etc/hosts
        fi

        echo "${IP} ${HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null

        log_info "Entrée hosts Linux configurée."
    fi
}

wait_for_grafana() {

    log_info "Attente du déploiement Grafana..."

    kubectl rollout status deployment/grafana \
        -n scloud-observability \
        --timeout=300s || true
}

################################################################################
# MAIN
################################################################################

main() {

    check_dependencies
    install_k3s

    for entry in "${REPOS[@]}"
    do
        IFS='|' read -r repo folder <<< "$entry"

        install_release \
            "$repo" \
            "$folder"
    done

    log_info "Téléchargement terminé."
    log_info "Starting all projects..."
    log_info "Starting scloud-observability..."
    cd scloud-observability
    ./deploy-scloud-observability.sh
    wait_for_grafana
    configure_grafana_ingress_dns

    cd ../scloud-dns
    echo "Vérification du namespace scloud-dns..."
    if ! kubectl get namespace scloud-dns >/dev/null 2>&1; then
        echo "Création du namespace scloud-dns..."
        kubectl create namespace scloud-dns
    else
        echo "✅ Namespace scloud-dns déjà existant"
    fi
    kubectl apply -f k3s/scloud-dns.yaml

    echo
    log_info "Installing Kubernetes dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
    kubectl proxy --address=0.0.0.0 --accept-hosts='.*' >/tmp/kubectl-proxy.log 2>&1 &
    log_info "Creating the admin user for the dashboard..."
    kubectl create serviceaccount admin-user -n kubernetes-dashboard
    kubectl create clusterrolebinding admin-user --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:admin-user
    TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user)

    echo
    log_info "Endpoints:"
    log_info "  Dashboard: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    log_info "    TOKEN: ${TOKEN}"
    log_info "  Grafana: http://observability.scloud.moe"
}

main "$@"