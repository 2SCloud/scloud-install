#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# CONFIGURATION
################################################################################

BASE_DIR="$(pwd)"
TMP_DIR="$(mktemp -d)"
VERSION_FILE="${TMP_DIR}/.task-version"   # tasks write the version they fetched here

# Full log of every command (stdout + stderr): shown on failure
LOG_FILE="${LOG_FILE:-${BASE_DIR}/scloud-install.log}"

# Downloaded releases (unchanged)
REPOS=(
    "2SCloud/scloud-dns|scloud-dns"
    "2SCloud/scloud-observability|scloud-observability"
)

# Parent repo: scloud-edge-gateway (edge-gateway Dockerfile + frontend/).
# scloud-compute (manifests + legacy deploy.sh) is embedded in it: it is the
# "REPO_ROOT" of the old deploy.sh, and the Docker build context is its parent.
PLATFORM_REPO="${PLATFORM_REPO:-2SCloud/scloud-edge-gateway}"
PLATFORM_DIR="${BASE_DIR}/platform-repo"

# scloud-compute : manifests (platform/, dns/, gateway/, frontend/, observability/).
# Detected in the parent repo; otherwise cloned separately into ./scloud-compute.
COMPUTE_REPO="${COMPUTE_REPO:-2SCloud/scloud-compute}"
COMPUTE_DIR="${BASE_DIR}/scloud-compute"
REPO_ROOT=""        # = scloud-compute root, set by clone_platform_repo
BUILD_CONTEXT=""    # Docker build context of the edge-gateway

# Submodules declared over SSH (git@github.com:...) fail without an SSH key:
# we rewrite them to HTTPS for every git command in this script.
GIT_HTTPS=(-c "url.https://github.com/.insteadOf=git@github.com:")

# SKIP_OBSERVABILITY=1 ./install.sh  → does not deploy the observability stack
# (hosts with less than ~6 GiB of RAM: Mimir/Loki/Tempo cause OOMs).
SKIP_OBSERVABILITY="${SKIP_OBSERVABILITY:-0}"

# VERBOSE=1 ./install.sh  → also shows skipped tasks and informational messages
VERBOSE="${VERBOSE:-0}"

# SKIP_BUILD=1 ./install.sh  → does not touch Docker: reuses the images already
# loaded in k3s (useful when the Docker daemon is unresponsive).
SKIP_BUILD="${SKIP_BUILD:-0}"

DASHBOARD_TOKEN=""
CURRENT_PID=""
SUDO_PID=""

################################################################################
# UI: colors, spinner, progress bar
#   NO_COLOR=1  → disables colors
#   Non-interactive output (pipe, CI) → no animation, plain logs
################################################################################

IS_TTY=0
if [[ -t 1 ]]; then IS_TTY=1; fi

C_RESET="" C_BOLD="" C_DIM="" C_GRAY="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
if (( IS_TTY )) && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GRAY=$'\033[90m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF8=1 ;;
    *) UTF8=0 ;;
esac

if (( UTF8 )); then
    SPIN_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    BAR_FULL="█" BAR_EMPTY="░"
    ICON_OK="✔" ICON_FAIL="✘" ICON_WARN="⚠" ICON_SKIP="↷" ICON_INFO="ℹ"
    ELLIPSIS="…" RULE="━━"
else
    SPIN_FRAMES=("|" "/" "-" "\\")
    BAR_FULL="#" BAR_EMPTY="-"
    ICON_OK="OK" ICON_FAIL="XX" ICON_WARN="!!" ICON_SKIP=">>" ICON_INFO="i"
    ELLIPSIS="~" RULE="=="
fi

TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
[[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=80

TOTAL_TASKS=51
DONE_TASKS=0
FMT_TIME=""

_fmt_time() {
    local s="$1"
    if (( s >= 60 )); then
        printf -v FMT_TIME '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf -v FMT_TIME '%ds' "$s"
    fi
}

progress_bar() {
    local cur="$1" total="$2" width="${3:-22}"
    if (( total < 1 )); then total=1; fi
    if (( cur > total )); then cur=$total; fi

    local filled=$(( cur * width / total ))
    local pct=$(( cur * 100 / total ))
    local full="" empty="" i

    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then full+="$BAR_FULL"; else empty+="$BAR_EMPTY"; fi
    done

    printf '[%s%s%s%s%s] %3d%%' "$C_GREEN" "$full" "$C_DIM" "$empty" "$C_RESET" "$pct"
}

bump() { TOTAL_TASKS=$(( TOTAL_TASKS + ${1:-1} )); }
tick() { DONE_TASKS=$(( DONE_TASKS + 1 )); }

_retry() {
    local attempts="$1" i
    shift
    for (( i = 1; i <= attempts; i++ )); do
        if "$@"; then return 0; fi
        echo "Attempt ${i}/${attempts} failed; retrying in 10s..."
        sleep 10
    done
    return 1
}

report_version() {
    if [[ -n "${1:-}" ]]; then printf '%s' "$1" >"$VERSION_FILE"; fi
}

_tool_version() {
    "$1" --version 2>/dev/null | grep -oE 'v?[0-9]+(\.[0-9]+)+(\+[A-Za-z0-9]+)?' | head -n1 || true
}

_kubectl_version() {
    kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n1 || true
}

_cert_manager_version() {
    kubectl get deployment cert-manager -n cert-manager \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://' || true
}

_repo_version() {
    git -C "$1" describe --tags --always 2>/dev/null || git -C "$1" rev-parse --short HEAD 2>/dev/null || true
}

banner() {
    echo
    if (( UTF8 )); then
        printf '%s' "$C_CYAN$C_BOLD"
        echo "  ╭────────────────────────────────────────────╮"
        echo "  │   2SCloud · private cloud bootstrap  (k8s) │"
        echo "  ╰────────────────────────────────────────────╯"
        printf '%s' "$C_RESET"
    else
        echo "  == 2SCloud - private cloud bootstrap (k8s) =="
    fi
    printf '  %sFull log: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET"
}

################################################################################
# LOGGING
################################################################################

log_info() {
    if [[ -t 1 ]]; then
        printf '  %s%s%s %s\n' "$C_BLUE" "$ICON_INFO" "$C_RESET" "$*"
    else
        echo "[INFO ] $*"
    fi
}

log_detail() {
    if [[ "$VERBOSE" == "1" || ! -t 1 ]]; then log_info "$@"; fi
}

log_warn() {
    if [[ -t 2 ]]; then
        printf '  %s%s %s%s\n' "$C_YELLOW" "$ICON_WARN" "$*" "$C_RESET" >&2
    else
        echo "[WARN ] $*" >&2
    fi
}

log_error() {
    if [[ -t 2 ]]; then
        printf '  %s%s %s%s\n' "$C_RED" "$ICON_FAIL" "$*" "$C_RESET" >&2
    else
        echo "[ERROR] $*" >&2
    fi
}

step() {
    echo
    printf '%s%s [scloud] %s%s\n' "$C_BOLD$C_CYAN" "$RULE" "$*" "$C_RESET"
}

################################################################################
# TASK RUNNER (spinner + progress bar)
#
#   run      "label" cmd args...   → runs in the background, failure = abort
#   run_soft "label" cmd args...   → same, but a failure is only a warning
#   skip     "label" [weight]       → skipped task (still counts toward progress)
#
# ⚠ The command runs in a subshell: it can NOT modify the script's
#   variables (export, REPO_ROOT=...). Such assignments therefore stay in
#   the foreground, outside of run().
################################################################################

_draw_live() {
    local frame="$1" label="$2" elapsed="$3" bar="$4"
    local max=$(( TERM_COLS - 48 ))
    if (( max < 20 )); then max=20; fi
    if (( ${#label} > max )); then label="${label:0:max-1}${ELLIPSIS}"; fi

    _fmt_time "$elapsed"
    printf '\r\033[2K %s%s%s %-*s %s%6s%s  %s' \
        "$C_CYAN" "$frame" "$C_RESET" \
        "$max" "$label" \
        "$C_DIM" "$FMT_TIME" "$C_RESET" \
        "$bar"
}

_run_task() {
    local soft="$1" label="$2"
    shift 2

    local start=$SECONDS rc=0 i=0 bar=""
    local nframes=${#SPIN_FRAMES[@]}

    {
        printf '\n[%s] ### %s\n' "$(date +%T)" "$label"
        printf '$ %s\n' "$*"
    } >>"$LOG_FILE"

    rm -f "$VERSION_FILE"
    "$@" </dev/null >>"$LOG_FILE" 2>&1 &
    CURRENT_PID=$!

    if (( IS_TTY )); then
        bar="$(progress_bar "$DONE_TASKS" "$TOTAL_TASKS")"
        printf '\033[?25l'
        while kill -0 "$CURRENT_PID" 2>/dev/null; do
            _draw_live "${SPIN_FRAMES[i % nframes]}" "$label" "$(( SECONDS - start ))" "$bar"
            i=$(( i + 1 ))
            sleep 0.08
        done
        printf '\r\033[2K\033[?25h'
    else
        printf '==> %s\n' "$label"
    fi

    if wait "$CURRENT_PID"; then rc=0; else rc=$?; fi
    CURRENT_PID=""

    _fmt_time "$(( SECONDS - start ))"
    local elapsed="$FMT_TIME"

    local ver_str=""
    if [[ -f "$VERSION_FILE" ]]; then
        ver_str=" ${C_GRAY}($(<"$VERSION_FILE"))${C_RESET}"
    fi

    if (( rc == 0 )); then
        tick
        printf ' %s%s%s %s%s %s%s%s\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "$label" "$ver_str" "$C_DIM" "$elapsed" "$C_RESET"
        return 0
    fi

    if (( soft )); then
        tick
        printf ' %s%s %s%s %s%s%s\n' "$C_YELLOW" "$ICON_WARN" "$label" "$C_RESET" "$C_DIM" "$elapsed" "$C_RESET"
        tail -n 10 "$LOG_FILE" | sed "s/^/     ${C_DIM}│${C_RESET} /"
        return 0
    fi

    printf ' %s%s %s%s %s(failed after %s)%s\n' "$C_RED" "$ICON_FAIL" "$label" "$C_RESET" "$C_DIM" "$elapsed" "$C_RESET" >&2
    echo >&2
    printf '   %sLast log lines:%s\n' "$C_BOLD" "$C_RESET" >&2
    tail -n 20 "$LOG_FILE" | sed "s/^/     ${C_DIM}│${C_RESET} /" >&2
    echo >&2
    printf '   %sFull log: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
    exit "$rc"
}

run()      { _run_task 0 "$@"; }
run_soft() { _run_task 1 "$@"; }

skip() {
    local label="$1" weight="${2:-1}" ver="${3:-}"
    DONE_TASKS=$(( DONE_TASKS + weight ))
    if [[ "$VERBOSE" == "1" ]]; then
        local ver_str=""
        if [[ -n "$ver" ]]; then ver_str=" ${C_GRAY}(${ver})${C_RESET}"; fi
        printf ' %s%s %s%s%s\n' "$C_DIM" "$ICON_SKIP" "$label" "$C_RESET" "$ver_str"
    fi
}

################################################################################
# CLEANUP / SIGNAUX
################################################################################

cleanup() {
    if (( IS_TTY )); then printf '\033[?25h'; fi
    if [[ -n "$CURRENT_PID" ]]; then
        pkill -P "$CURRENT_PID" 2>/dev/null || true
        kill "$CURRENT_PID" 2>/dev/null || true
    fi
    if [[ -n "$SUDO_PID" ]]; then
        kill "$SUDO_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}

on_interrupt() {
    if (( IS_TTY )); then printf '\r\033[2K'; fi
    log_error "Interrupted by user."
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

prime_sudo() {
    if [[ $EUID -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
        return 0
    fi

    log_info "sudo authentication (asked only once)..."
    sudo -v

    (
        while true; do
            sudo -n true 2>/dev/null || true
            sleep 50
            kill -0 "$$" 2>/dev/null || exit 0
        done
    ) &
    SUDO_PID=$!
}

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

        echo "Unsupported package manager." >&2
        exit 1

    fi

    report_version "$(_tool_version "$pkg")"
}

_do_install_helm() {

    local version
    version=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
    report_version "$version"

    cd "$TMP_DIR"

    curl -fsSL -o helm.tar.gz \
        "https://get.helm.sh/helm-${version}-linux-amd64.tar.gz"

    tar -xzf helm.tar.gz

    sudo install -m 755 linux-amd64/helm /usr/local/bin/helm

    helm version --short
}

install_helm() {

    if command -v helm >/dev/null 2>&1; then
        skip "Helm already installed" 1 "$(helm version --short 2>/dev/null || true)"
        return 0
    fi

    run "Installing Helm" _do_install_helm
}

_do_install_docker() {

    curl -fsSL https://get.docker.com | sudo sh

    report_version "$(_tool_version docker)"
    command -v docker >/dev/null 2>&1
}

install_docker() {

    if command -v docker >/dev/null 2>&1; then
        skip "Docker already installed" 1 "$(_tool_version docker)"
        return 0
    fi

    run "Installing Docker" _do_install_docker
}

_do_install_k3s() {

    curl -sfL https://get.k3s.io | sh -

    report_version "$(_tool_version k3s)"

    mkdir -p "$HOME/.kube"

    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"

    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

    export KUBECONFIG="$HOME/.kube/config"

    echo "Waiting for k3s to start..."

    local i
    for i in {1..30}
    do
        if kubectl get nodes >/dev/null 2>&1; then
            echo "Kubernetes cluster ready."
            return 0
        fi

        sleep 2
    done

    echo "The k3s cluster is not responding." >&2
    return 1
}

install_k3s() {

    if kubectl cluster-info >/dev/null 2>&1; then
        skip "Kubernetes cluster already reachable"
        return 0
    fi

    run "Installing k3s (+ waiting for the cluster)" _do_install_k3s

    export KUBECONFIG="$HOME/.kube/config"
}

_do_install_kubectl() {

    local version
    version=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
    report_version "$version"

    curl -fsSL \
        -o "${TMP_DIR}/kubectl" \
        "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"

    chmod +x "${TMP_DIR}/kubectl"

    sudo install -m 0755 "${TMP_DIR}/kubectl" /usr/local/bin/kubectl

    command -v kubectl >/dev/null 2>&1
}

install_kubectl() {

    if command -v kubectl >/dev/null 2>&1; then
        skip "kubectl already installed" 1 "$(_kubectl_version)"
        return 0
    fi

    run "Installing kubectl" _do_install_kubectl
}

_do_install_cert_manager() {

    kubectl apply -f \
        https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

    local d
    for d in cert-manager cert-manager-cainjector cert-manager-webhook
    do
        kubectl rollout status "deployment/${d}" -n cert-manager --timeout=180s
    done

    report_version "$(_cert_manager_version)"
}

install_cert_manager() {

    if kubectl get namespace cert-manager >/dev/null 2>&1 \
       && kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
        skip "cert-manager already installed" 1 "$(_cert_manager_version)"
        return 0
    fi

    run "Installing cert-manager (3 deployments)" _do_install_cert_manager
}

check_dependencies() {

    declare -A packages=(
        [curl]="curl"
        [jq]="jq"
        [tar]="tar"
        [git]="git"
        [sed]="sed"
    )

    local cmd
    for cmd in "${!packages[@]}"
    do
        if ! command -v "$cmd" >/dev/null 2>&1; then

            bump 1
            run "Installing $cmd" install_package "${packages[$cmd]}"
        fi
    done

    install_helm
    install_kubectl
    install_docker
    log_detail "All dependencies are installed."
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

    log_info "Downloading ${repo}"

    local tag

    tag=$(get_latest_tag "$repo")

    if [[ -z "$tag" || "$tag" == "null" ]]; then

        log_error "Release not found for ${repo}"
        return 1

    fi

    log_info "Release detected: ${tag}"
    report_version "$tag"

    local archive_file
    archive_file="${TMP_DIR}/${folder}.tar.gz"

    local archive_url
    archive_url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"

    curl -fsSL \
        "$archive_url" \
        -o "$archive_file"

    mkdir -p "${BASE_DIR}/${folder}"

    tar -xzf \
        "$archive_file" \
        -C "${BASE_DIR}/${folder}" \
        --strip-components=1

    log_info "Sources extracted to ${BASE_DIR}/${folder}"
}

_git_clone() {
    git "${GIT_HTTPS[@]}" clone "$1" "$2"
    report_version "$(_repo_version "$2")"
}

_git_pull() {
    git "${GIT_HTTPS[@]}" -C "$1" pull --ff-only
    report_version "$(_repo_version "$1")"
}

clone_platform_repo() {

    export GIT_TERMINAL_PROMPT=0

    if [[ -d "${PLATFORM_DIR}/.git" ]]; then
        run_soft "Updating ${PLATFORM_REPO}" _git_pull "$PLATFORM_DIR"
    else
        run "Cloning ${PLATFORM_REPO}" \
            _git_clone "https://github.com/${PLATFORM_REPO}.git" "$PLATFORM_DIR"
    fi

    run_soft "Git submodules (SSH → HTTPS)" \
        git "${GIT_HTTPS[@]}" -C "$PLATFORM_DIR" submodule update --init --recursive

    local pki
    pki=$(find "$PLATFORM_DIR" -type d -path '*/platform/pki' \
            -not -path '*/.git/*' -not -path '*/node_modules/*' | head -n1)

    if [[ -n "$pki" ]]; then
        REPO_ROOT="$(dirname "$(dirname "$pki")")"
    else
        log_warn "scloud-compute not found in ${PLATFORM_REPO}, cloning ${COMPUTE_REPO} directly..."
        bump 2

        if [[ -d "${COMPUTE_DIR}/.git" ]]; then
            run_soft "Updating ${COMPUTE_REPO}" _git_pull "$COMPUTE_DIR"
        else
            run "Cloning ${COMPUTE_REPO}" \
                _git_clone "https://github.com/${COMPUTE_REPO}.git" "$COMPUTE_DIR"
        fi

        run_soft "Submodules of ${COMPUTE_REPO}" \
            git "${GIT_HTTPS[@]}" -C "$COMPUTE_DIR" submodule update --init --recursive

        REPO_ROOT="$COMPUTE_DIR"
    fi

    if [[ ! -d "$REPO_ROOT/platform/pki" ]]; then
        log_error "scloud-compute manifests not found (platform/pki missing) in ${REPO_ROOT}."
        exit 1
    fi

    if [[ -f "${REPO_ROOT}/../Dockerfile" ]]; then
        BUILD_CONTEXT="$(cd "${REPO_ROOT}/.." && pwd)"
    else
        BUILD_CONTEXT="$PLATFORM_DIR"
    fi

    log_detail "scloud-compute (REPO_ROOT) : ${REPO_ROOT}"
    log_detail "Docker build context       : ${BUILD_CONTEXT}"
}

################################################################################
# BUILD & LOAD IMAGES
################################################################################

_check_docker() {
    local out
    if out=$(timeout 30 docker version --format '{{.Server.Version}}' 2>&1) && [[ -n "$out" ]]; then
        report_version "$out"
        return 0
    fi

    echo "Docker daemon not responding${out:+: ${out}}" >&2
    echo "→ Restart Docker Desktop (run 'wsl --shutdown' from Windows, then start it again)," >&2
    echo "  or re-run with SKIP_BUILD=1 if the images are already loaded in k3s." >&2
    return 1
}

_build_image() {
    DOCKER_BUILDKIT=1 docker build --progress=plain -t "$1" "$2"
    report_version "$(docker image inspect -f '{{.Id}}' "$1" | sed 's/^sha256://' | cut -c1-12)"
}

_import_image() {
    docker save "$1" | sudo k3s ctr images import -
}

build_images() {

    step "0/5  Building images"

    if [[ "$SKIP_BUILD" == "1" ]]; then
        local images
        images=$(sudo k3s ctr images ls -q 2>/dev/null || true)
        if ! grep -q '2scloud/edge-gateway' <<<"$images" || ! grep -q '2scloud/frontend' <<<"$images"; then
            log_error "SKIP_BUILD=1 but 2scloud/edge-gateway and/or 2scloud/frontend are not loaded in k3s."
            log_error "Run once without SKIP_BUILD (Docker must be healthy)."
            exit 1
        fi
        skip "Docker build skipped (SKIP_BUILD=1): images already loaded in k3s" 4
        return 0
    fi

    if [[ ! -f "$BUILD_CONTEXT/Dockerfile" || ! -f "$BUILD_CONTEXT/frontend/Dockerfile" ]]; then
        log_error "Dockerfile not found in ${BUILD_CONTEXT} (or ${BUILD_CONTEXT}/frontend)."
        exit 1
    fi

    bump 1
    run "Checking Docker daemon" _check_docker

    run "Build 2scloud/edge-gateway:latest"      _build_image 2scloud/edge-gateway:latest "$BUILD_CONTEXT"
    run "Import edge-gateway → k3s"              _import_image 2scloud/edge-gateway:latest

    run "Build 2scloud/frontend:latest"          _build_image 2scloud/frontend:latest "$BUILD_CONTEXT/frontend"
    run "Import frontend → k3s"                  _import_image 2scloud/frontend:latest
}

################################################################################
# PLATFORM PKI
################################################################################

deploy_pki() {

    step "0/5  Deploying platform PKI"

    run "PKI: bootstrap issuer + root CA + internal CA" \
        _retry 3 kubectl apply -f "$REPO_ROOT/platform/pki/"

    run "Waiting for certificate scloud-internal-root-ca" \
        kubectl wait --for=condition=Ready certificate/scloud-internal-root-ca \
            -n cert-manager --timeout=120s

    run "Waiting for ClusterIssuer scloud-internal-ca" \
        kubectl wait --for=condition=Ready clusterissuer/scloud-internal-ca --timeout=60s
}

################################################################################
# GRAFANA ACCESS
################################################################################

configure_grafana_ingress_dns() {

    local HOSTNAME="observability.scloud.moe"

    log_info "Configuring local DNS ${HOSTNAME}..."

    local IP

    IP=$(kubectl get nodes \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    if grep -qi microsoft /proc/version 2>/dev/null; then

        log_info "WSL detected"

        if powershell.exe -Command "
\$hosts='C:\Windows\System32\drivers\etc\hosts'

if (Test-Path \$hosts) {

    \$content = Get-Content \$hosts -ErrorAction SilentlyContinue

    \$newContent = \$content | Where-Object { \$_ -notmatch '${HOSTNAME}' }

    Set-Content -Path \$hosts -Value \$newContent

    Add-Content -Path \$hosts -Value '${IP} ${HOSTNAME}'
}
" >/dev/null 2>&1; then

            log_info "Windows hosts entry configured."

        else

            log_warn "Could not automatically edit the Windows hosts file."

            echo
            log_warn "Open PowerShell as Administrator and run:"
            echo
            echo "Add-Content C:\Windows\System32\drivers\etc\hosts '${IP} ${HOSTNAME}'"
            echo

            return 1
        fi

    elif [[ "$OSTYPE" == "darwin"* ]]; then

        if grep -q "${HOSTNAME}" /etc/hosts 2>/dev/null; then

            sudo sed -i '' "/${HOSTNAME}/d" /etc/hosts
        fi

        echo "${IP} ${HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null

        log_info "macOS hosts entry configured."

    else

        if grep -q "${HOSTNAME}" /etc/hosts 2>/dev/null; then

            sudo sed -i "/${HOSTNAME}/d" /etc/hosts
        fi

        echo "${IP} ${HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null

        log_info "Linux hosts entry configured."
    fi
}

wait_for_grafana() {

    run_soft "Waiting for Grafana deployment" \
        kubectl rollout status deployment/grafana \
            -n scloud-observability \
            --timeout=300s
}

################################################################################
# 1. OBSERVABILITY
################################################################################

_run_observability_script() {
    cd "$BASE_DIR/scloud-observability" && bash ./deploy-scloud-observability.sh
}

deploy_observability() {

    if [[ "$SKIP_OBSERVABILITY" == "1" ]]; then
        step "1/5  Skipping scloud-observability (SKIP_OBSERVABILITY=1)"
        skip "scloud-observability skipped (SKIP_OBSERVABILITY=1)" 8
        log_detail "Observability stack not deployed. Other components will still run."
        log_detail "(scloud-dns will log one warning per OTEL export, with no impact on DNS.)"
        return 0
    fi

    step "1/5  Deploying scloud-observability"

    run "Deploying scloud-observability" _run_observability_script

    wait_for_grafana
    run_soft "Local DNS entry for observability.scloud.moe" configure_grafana_ingress_dns

    run "Observability: RBAC" \
        _retry 3 kubectl apply \
            -f "$REPO_ROOT/observability/rbac/clusterrole.yaml" \
            -f "$REPO_ROOT/observability/rbac/clusterrolebinding.yaml" \
            -f "$REPO_ROOT/observability/rbac/serviceaccount.yaml"

    run "Observability: governance" \
        _retry 3 kubectl apply -f "$REPO_ROOT/observability/governance/"

    run "Observability: storage" \
        _retry 3 kubectl apply -f "$REPO_ROOT/observability/storage/"

    run "Observability: Mimir (monolithic)" \
        _retry 3 kubectl apply -f "$REPO_ROOT/observability/workloads/mimir/"

    run "Observability: network policies" \
        _retry 3 kubectl apply -f "$REPO_ROOT/observability/network/netpol.yaml"
}

################################################################################
# 2. DNS
################################################################################

_ensure_namespace_dns() {
    kubectl get namespace scloud-dns >/dev/null 2>&1 \
        || kubectl create namespace scloud-dns
}

_patch_coredns() {
    local ip
    ip=$(kubectl get svc scloud-dns -n scloud-dns -o jsonpath='{.spec.clusterIP}')

    sed "s|scloud-dns.scloud-dns.svc.cluster.local:53|${ip}:53|g" \
        "$REPO_ROOT/dns/coredns/coredns-patch.yaml" | kubectl apply -f -
}

deploy_dns() {

    step "2/5  Deploying scloud-dns"

    run "Namespace scloud-dns" _ensure_namespace_dns

    if [[ -d "$REPO_ROOT/dns/workloads" ]]; then

        run "scloud-dns: namespace"        _retry 3 kubectl apply -f "$REPO_ROOT/dns/namespace.yaml"
        run "scloud-dns: RBAC"             _retry 3 kubectl apply -f "$REPO_ROOT/dns/rbac/"
        run "scloud-dns: network policies" _retry 3 kubectl apply -f "$REPO_ROOT/dns/network/"
        run "scloud-dns: configuration"    _retry 3 kubectl apply -f "$REPO_ROOT/dns/config/"
        run "scloud-dns: workloads"        _retry 3 kubectl apply -f "$REPO_ROOT/dns/workloads/"

        run "CoreDNS: stub zone scloud.internal" _patch_coredns
        log_detail "CoreDNS will hot-reload the stub zone via the reload plugin (~30s)"

    else

        log_warn "dns/ manifests not found in the platform, using the scloud-dns release."
        run "scloud-dns: release manifest" \
            _retry 3 kubectl apply -f "$BASE_DIR/scloud-dns/k3s/scloud-dns.yaml"
        skip "Detailed scloud-dns steps (not applicable)" 5

    fi
}

################################################################################
# 3. EDGE GATEWAY
################################################################################

deploy_gateway() {

    step "3/5  Deploying scloud-edge-gateway"

    run "Gateway: namespace"     _retry 3 kubectl apply -f "$REPO_ROOT/gateway/namespace.yaml"
    run "Gateway: RBAC"          _retry 3 kubectl apply -f "$REPO_ROOT/gateway/rbac/"
    run "Gateway: governance"    _retry 3 kubectl apply -f "$REPO_ROOT/gateway/governance/"
    run "Gateway: configuration" _retry 3 kubectl apply -f "$REPO_ROOT/gateway/config/"

    run "Waiting for edge-gateway TLS certificate" \
        kubectl wait --for=condition=Ready certificate/edge-gateway-tls \
            -n scloud-gateway --timeout=120s

    run "Gateway: workloads"     _retry 3 kubectl apply -f "$REPO_ROOT/gateway/workloads/"
}

################################################################################
# 4. COMPUTE (PLATFORM)
################################################################################

deploy_platform() {

    step "4/5  Deploying scloud-compute platform"

    local src="$REPO_ROOT/platform"
    log_detail "Manifests source: ${src}"

    run "Compute: namespace"        _retry 3 kubectl apply -f "$src/namespace.yaml"
    run "Compute: RBAC"             _retry 3 kubectl apply -f "$src/rbac/"
    run "Compute: governance"       _retry 3 kubectl apply -f "$src/governance/"
    run "Compute: network policies" _retry 3 kubectl apply -f "$src/network/"
    run "Compute: workloads"        _retry 3 kubectl apply -f "$src/workloads/"

    run "Waiting for rollout of nginx-deployment" \
        kubectl rollout status deployment/nginx-deployment -n scloud-compute --timeout=120s
}

################################################################################
# 5. FRONTEND (ADMIN UI)
################################################################################

deploy_frontend() {

    step "5/5  Deploying scloud-frontend"

    run "Frontend: namespace"        _retry 3 kubectl apply -f "$REPO_ROOT/frontend/namespace.yaml"
    run "Frontend: configuration"    _retry 3 kubectl apply -f "$REPO_ROOT/frontend/config/"
    run "Frontend: network policies" _retry 3 kubectl apply -f "$REPO_ROOT/frontend/network/"
    run "Frontend: workloads"        _retry 3 kubectl apply -f "$REPO_ROOT/frontend/workloads/"

    run "Waiting for rollout of scloud-frontend" \
        kubectl rollout status deployment/scloud-frontend -n scloud-frontend --timeout=120s
}

################################################################################
# KUBERNETES DASHBOARD
################################################################################

_create_dashboard_admin() {
    kubectl create serviceaccount admin-user -n kubernetes-dashboard 2>/dev/null || true
    kubectl create clusterrolebinding admin-user \
        --clusterrole=cluster-admin \
        --serviceaccount=kubernetes-dashboard:admin-user 2>/dev/null || true
}

DASHBOARD_VERSION="v2.7.0"

_install_dashboard() {
    report_version "$DASHBOARD_VERSION"
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"
}

install_k8s_dashboard() {

    step "Kubernetes dashboard"

    run "Installing Kubernetes dashboard" _install_dashboard

    nohup kubectl proxy --address=0.0.0.0 --accept-hosts='.*' \
        >/tmp/kubectl-proxy.log 2>&1 </dev/null &
    disown 2>/dev/null || true

    run "Creating dashboard admin user" _create_dashboard_admin

    DASHBOARD_TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user)
    tick
    printf ' %s%s%s %s\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "Dashboard token generated"
}

################################################################################
# SUMMARY
################################################################################

print_summary() {

    DONE_TASKS=$TOTAL_TASKS
    _fmt_time "$SECONDS"

    step "2SCloud private cloud bootstrap complete  (${FMT_TIME})"
    printf '  %s\n' "$(progress_bar "$DONE_TASKS" "$TOTAL_TASKS" 30)"
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
    log_info "                 then http://localhost:3000  (admin / admin)"
    log_info "  Admin API    : kubectl port-forward -n scloud-gateway svc/edge-gateway-admin 9090:9090"
    log_info "  DNS          : scloud-dns.scloud-dns.svc:53"
    echo
    log_warn "IMPORTANT: change the Grafana admin password before exposing the cluster."
    log_warn "            See observability/workloads/grafana/deployment.yaml → GF_SECURITY_ADMIN_PASSWORD"
    echo
}

################################################################################
# MAIN
################################################################################

main() {

    : >"$LOG_FILE"

    banner
    prime_sudo

    step "Preparation: dependencies & cluster"
    check_dependencies
    install_k3s
    install_cert_manager

    step "Downloading releases"
    local entry repo folder
    for entry in "${REPOS[@]}"
    do
        IFS='|' read -r repo folder <<< "$entry"

        run "Downloading ${repo}" install_release "$repo" "$folder"
    done

    clone_platform_repo

    log_detail "Download complete. Starting all projects..."

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