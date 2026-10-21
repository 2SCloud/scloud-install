#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# CONFIGURATION
################################################################################

BASE_DIR="$(pwd)"
TMP_DIR="$(mktemp -d)"

# Releases téléchargées (inchangé)
REPOS=(
    "2SCloud/scloud-dns|scloud-dns"
    "2SCloud/scloud-observability|scloud-observability"
)

# Dépôt parent : scloud-edge-gateway (Dockerfile de l'edge-gateway + frontend/).
# scloud-compute (manifests + deploy.sh historique) y est embarqué : c'est le
# "REPO_ROOT" de l'ancien deploy.sh, et le contexte de build Docker est son parent.
PLATFORM_REPO="${PLATFORM_REPO:-2SCloud/scloud-edge-gateway}"
PLATFORM_DIR="${BASE_DIR}/platform-repo"

# scloud-compute : manifests (platform/, dns/, gateway/, frontend/, observability/).
# Détecté dans le dépôt parent ; sinon cloné séparément dans ./scloud-compute.
COMPUTE_REPO="${COMPUTE_REPO:-2SCloud/scloud-compute}"
COMPUTE_DIR="${BASE_DIR}/scloud-compute"
REPO_ROOT=""        # = racine de scloud-compute, défini par clone_platform_repo
BUILD_CONTEXT=""    # contexte de build Docker de l'edge-gateway

# Les sous-modules déclarés en SSH (git@github.com:...) échouent sans clé SSH :
# on les réécrit en HTTPS pour toutes les commandes git du script.
GIT_HTTPS=(-c "url.https://github.com/.insteadOf=git@github.com:")

# SKIP_OBSERVABILITY=1 ./install.sh  → ne déploie pas la stack d'observabilité
# (hôtes avec moins de ~6 GiB de RAM : Mimir/Loki/Tempo provoquent des OOM).
SKIP_OBSERVABILITY="${SKIP_OBSERVABILITY:-0}"

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

step() {
    echo
    echo "──────────────────────────────────────────────"
    echo "[scloud] $*"
    echo "──────────────────────────────────────────────"
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

    cd "$BASE_DIR"
}

install_docker() {

    if command -v docker >/dev/null 2>&1; then
        log_info "Docker déjà installé."
        return 0
    fi

    log_info "Docker n'est pas installé. Installation..."

    curl -fsSL https://get.docker.com | sudo sh

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Échec de l'installation de Docker."
        exit 1
    fi
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

# cert-manager est requis par la PKI de la plateforme (deploy.sh : "must already be installed")
install_cert_manager() {

    if kubectl get namespace cert-manager >/dev/null 2>&1 \
       && kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
        log_info "cert-manager déjà installé."
        return 0
    fi

    log_info "Installation de cert-manager..."

    kubectl apply -f \
        https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

    for d in cert-manager cert-manager-cainjector cert-manager-webhook
    do
        kubectl rollout status "deployment/${d}" -n cert-manager --timeout=180s
    done

    log_info "cert-manager prêt."
}

check_dependencies() {

    declare -A packages=(
        [curl]="curl"
        [jq]="jq"
        [tar]="tar"
        [git]="git"
        [sed]="sed"
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
    install_docker
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

# Dépôt parent + sous-modules (dont scloud-compute) ; repli sur un clone direct de scloud-compute.
clone_platform_repo() {

    export GIT_TERMINAL_PROMPT=0

    log_info "Récupération du dépôt ${PLATFORM_REPO}..."

    if [[ -d "${PLATFORM_DIR}/.git" ]]; then
        git "${GIT_HTTPS[@]}" -C "$PLATFORM_DIR" pull --ff-only || log_warn "Mise à jour impossible, version locale conservée."
    else
        git "${GIT_HTTPS[@]}" clone "https://github.com/${PLATFORM_REPO}.git" "$PLATFORM_DIR"
    fi

    log_info "Initialisation des sous-modules (SSH → HTTPS)..."
    git "${GIT_HTTPS[@]}" -C "$PLATFORM_DIR" submodule update --init --recursive \
        || log_warn "Certains sous-modules n'ont pas pu être récupérés."

    # 1) scloud-compute embarqué dans le dépôt parent (dossier contenant platform/pki)
    local pki
    pki=$(find "$PLATFORM_DIR" -type d -path '*/platform/pki' \
            -not -path '*/.git/*' -not -path '*/node_modules/*' | head -n1)

    if [[ -n "$pki" ]]; then
        REPO_ROOT="$(dirname "$(dirname "$pki")")"
    else
        # 2) repli : clone direct de scloud-compute
        log_warn "scloud-compute introuvable dans ${PLATFORM_REPO}, clone direct de ${COMPUTE_REPO}..."
        if [[ -d "${COMPUTE_DIR}/.git" ]]; then
            git "${GIT_HTTPS[@]}" -C "$COMPUTE_DIR" pull --ff-only || true
        else
            git "${GIT_HTTPS[@]}" clone "https://github.com/${COMPUTE_REPO}.git" "$COMPUTE_DIR"
        fi
        git "${GIT_HTTPS[@]}" -C "$COMPUTE_DIR" submodule update --init --recursive || true
        REPO_ROOT="$COMPUTE_DIR"
    fi

    if [[ ! -d "$REPO_ROOT/platform/pki" ]]; then
        log_error "Manifests scloud-compute introuvables (platform/pki manquant) dans ${REPO_ROOT}."
        exit 1
    fi

    # Contexte de build : parent de scloud-compute s'il contient le Dockerfile, sinon le dépôt parent
    if [[ -f "${REPO_ROOT}/../Dockerfile" ]]; then
        BUILD_CONTEXT="$(cd "${REPO_ROOT}/.." && pwd)"
    else
        BUILD_CONTEXT="$PLATFORM_DIR"
    fi

    log_info "scloud-compute (REPO_ROOT) : ${REPO_ROOT}"
    log_info "Contexte de build Docker   : ${BUILD_CONTEXT}"
}

################################################################################
# BUILD & LOAD IMAGES
################################################################################

build_images() {

    step "0/5  Building images"

    if [[ ! -f "$BUILD_CONTEXT/Dockerfile" || ! -f "$BUILD_CONTEXT/frontend/Dockerfile" ]]; then
        log_error "Dockerfile introuvable dans ${BUILD_CONTEXT} (ou ${BUILD_CONTEXT}/frontend)."
        exit 1
    fi

    log_info "Building 2scloud/edge-gateway:latest..."
    docker build -t 2scloud/edge-gateway:latest "$BUILD_CONTEXT"

    log_info "Loading edge-gateway image into k3s..."
    docker save 2scloud/edge-gateway:latest | sudo k3s ctr images import -

    log_info "Building 2scloud/frontend:latest..."
    docker build -t 2scloud/frontend:latest "$BUILD_CONTEXT/frontend"

    log_info "Loading frontend image into k3s..."
    docker save 2scloud/frontend:latest | sudo k3s ctr images import -
}

################################################################################
# PLATFORM PKI
################################################################################

deploy_pki() {

    step "0/5  Deploying platform PKI"

    log_info "Applying PKI bootstrap issuer + root CA + internal CA issuer..."
    kubectl apply -f "$REPO_ROOT/platform/pki/"

    log_info "Waiting for scloud-internal-root-ca certificate to be issued..."
    kubectl wait --for=condition=Ready certificate/scloud-internal-root-ca \
        -n cert-manager --timeout=120s

    log_info "Waiting for scloud-internal-ca ClusterIssuer to be ready..."
    kubectl wait --for=condition=Ready clusterissuer/scloud-internal-ca --timeout=60s
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
# 1. OBSERVABILITY
################################################################################

deploy_observability() {

    if [[ "$SKIP_OBSERVABILITY" == "1" ]]; then
        step "1/5  Skipping scloud-observability (SKIP_OBSERVABILITY=1)"
        log_info "Observability stack not deployed. Other components will still run."
        log_info "(scloud-dns loguera un warning par export OTEL, sans impact sur le DNS.)"
        return 0
    fi

    step "1/5  Deploying scloud-observability"

    (cd "$BASE_DIR/scloud-observability" && bash ./deploy-scloud-observability.sh)

    wait_for_grafana
    configure_grafana_ingress_dns

    log_info "Applying observability RBAC..."
    kubectl apply -f "$REPO_ROOT/observability/rbac/clusterrole.yaml"
    kubectl apply -f "$REPO_ROOT/observability/rbac/clusterrolebinding.yaml"
    kubectl apply -f "$REPO_ROOT/observability/rbac/serviceaccount.yaml"

    log_info "Applying observability governance..."
    kubectl apply -f "$REPO_ROOT/observability/governance/"

    log_info "Applying observability storage..."
    kubectl apply -f "$REPO_ROOT/observability/storage/"

    log_info "Deploying Mimir (monolithic)..."
    kubectl apply -f "$REPO_ROOT/observability/workloads/mimir/"

    log_info "Applying observability network policies..."
    kubectl apply -f "$REPO_ROOT/observability/network/netpol.yaml"
}

################################################################################
# 2. DNS
################################################################################

deploy_dns() {

    step "2/5  Deploying scloud-dns"

    echo "Vérification du namespace scloud-dns..."
    if ! kubectl get namespace scloud-dns >/dev/null 2>&1; then
        echo "Création du namespace scloud-dns..."
        kubectl create namespace scloud-dns
    else
        echo "✅ Namespace scloud-dns déjà existant"
    fi

    # Manifests complets de la plateforme si présents, sinon manifeste de la release
    if [[ -d "$REPO_ROOT/dns/workloads" ]]; then

        kubectl apply -f "$REPO_ROOT/dns/namespace.yaml"

        log_info "Applying scloud-dns RBAC..."
        kubectl apply -f "$REPO_ROOT/dns/rbac/"

        log_info "Applying scloud-dns network policies..."
        kubectl apply -f "$REPO_ROOT/dns/network/"

        log_info "Applying scloud-dns configuration..."
        kubectl apply -f "$REPO_ROOT/dns/config/"

        log_info "Applying scloud-dns workloads..."
        kubectl apply -f "$REPO_ROOT/dns/workloads/"

        log_info "Patching CoreDNS with scloud.internal stub zone..."
        local SCLOUD_DNS_IP
        SCLOUD_DNS_IP=$(kubectl get svc scloud-dns -n scloud-dns -o jsonpath='{.spec.clusterIP}')
        sed "s|scloud-dns.scloud-dns.svc.cluster.local:53|${SCLOUD_DNS_IP}:53|g" \
            "$REPO_ROOT/dns/coredns/coredns-patch.yaml" | kubectl apply -f -
        log_info "CoreDNS will hot-reload the stub zone via the reload plugin (~30s)"

    else

        log_warn "Manifests dns/ introuvables dans la plateforme, utilisation de la release scloud-dns."
        kubectl apply -f "$BASE_DIR/scloud-dns/k3s/scloud-dns.yaml"

    fi
}

################################################################################
# 3. EDGE GATEWAY
################################################################################

deploy_gateway() {

    step "3/5  Deploying scloud-edge-gateway"

    kubectl apply -f "$REPO_ROOT/gateway/namespace.yaml"

    log_info "Applying scloud-edge-gateway RBAC..."
    kubectl apply -f "$REPO_ROOT/gateway/rbac/"

    log_info "Applying scloud-edge-gateway governance..."
    kubectl apply -f "$REPO_ROOT/gateway/governance/"

    log_info "Applying scloud-edge-gateway configuration..."
    kubectl apply -f "$REPO_ROOT/gateway/config/"

    log_info "Waiting for edge-gateway TLS certificate to be issued..."
    kubectl wait --for=condition=Ready certificate/edge-gateway-tls \
        -n scloud-gateway --timeout=120s

    log_info "Applying scloud-edge-gateway workloads..."
    kubectl apply -f "$REPO_ROOT/gateway/workloads/"

    log_info "edge-gateway deployed"
}

################################################################################
# 4. COMPUTE (PLATFORM)
################################################################################

deploy_platform() {

    step "4/5  Deploying scloud-compute platform"

    local src="$REPO_ROOT/platform"
    log_info "Source des manifests : ${src}"

    kubectl apply -f "$src/namespace.yaml"

    log_info "Applying scloud-compute RBAC..."
    kubectl apply -f "$src/rbac/"

    log_info "Applying scloud-compute governance..."
    kubectl apply -f "$src/governance/"

    log_info "Applying scloud-compute network policies..."
    kubectl apply -f "$src/network/"

    log_info "Applying scloud-compute workloads..."
    kubectl apply -f "$src/workloads/"

    log_info "Waiting for platform workloads to be ready..."
    kubectl rollout status deployment/nginx-deployment -n scloud-compute --timeout=120s
}

################################################################################
# 5. FRONTEND (ADMIN UI)
################################################################################

deploy_frontend() {

    step "5/5  Deploying scloud-frontend"

    kubectl apply -f "$REPO_ROOT/frontend/namespace.yaml"

    log_info "Applying scloud-frontend configuration..."
    kubectl apply -f "$REPO_ROOT/frontend/config/"

    log_info "Applying scloud-frontend network policies..."
    kubectl apply -f "$REPO_ROOT/frontend/network/"

    log_info "Applying scloud-frontend workloads..."
    kubectl apply -f "$REPO_ROOT/frontend/workloads/"

    log_info "Waiting for frontend to be ready..."
    kubectl rollout status deployment/scloud-frontend -n scloud-frontend --timeout=120s
}

################################################################################
# KUBERNETES DASHBOARD
################################################################################

install_k8s_dashboard() {

    echo
    log_info "Installing Kubernetes dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
    kubectl proxy --address=0.0.0.0 --accept-hosts='.*' >/tmp/kubectl-proxy.log 2>&1 &
    log_info "Creating the admin user for the dashboard..."
    kubectl create serviceaccount admin-user -n kubernetes-dashboard 2>/dev/null || true
    kubectl create clusterrolebinding admin-user --clusterrole=cluster-admin --serviceaccount=kubernetes-dashboard:admin-user 2>/dev/null || true
    DASHBOARD_TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user)
}

################################################################################
# SUMMARY
################################################################################

print_summary() {

    step "2SCloud private cloud bootstrap complete"
    echo
    log_info "Endpoints:"
    log_info "  Dashboard    : http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    log_info "    TOKEN: ${DASHBOARD_TOKEN}"

    if [[ "$SKIP_OBSERVABILITY" != "1" ]]; then
        log_info "  Grafana      : http://observability.scloud.moe  (admin / scloud-change-me)"
        log_info "  Prometheus   : http://prometheus.scloud.internal:9090"
    fi

    log_info "  Gateway HTTP : http://gateway.scloud.internal:30080"
    log_info "  Gateway TLS  : https://gateway.scloud.internal:30443   (DoH /dns-query)"
    log_info "  Frontend     : kubectl port-forward -n scloud-frontend svc/scloud-frontend 3000:80"
    log_info "                 puis http://localhost:3000  (admin / admin)"
    log_info "  Admin API    : kubectl port-forward -n scloud-gateway svc/edge-gateway-admin 9090:9090"
    log_info "  DNS          : scloud-dns.scloud-dns.svc:53"
    echo
    log_warn "IMPORTANT : changez le mot de passe admin de Grafana avant d'exposer le cluster."
    log_warn "            Voir observability/workloads/grafana/deployment.yaml → GF_SECURITY_ADMIN_PASSWORD"
    echo
}

################################################################################
# MAIN
################################################################################

main() {

    check_dependencies
    install_k3s
    install_cert_manager

    for entry in "${REPOS[@]}"
    do
        IFS='|' read -r repo folder <<< "$entry"

        install_release \
            "$repo" \
            "$folder"
    done

    clone_platform_repo

    sleep 2

    log_info "Téléchargement terminé."
    log_info "Starting all projects..."

    build_images
    deploy_pki
    deploy_observability
    deploy_dns
    deploy_gateway
    deploy_platform
    deploy_frontend
    install_k8s_dashboard
    print_summary
}

main "$@"
