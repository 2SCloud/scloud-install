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
# MAIN
################################################################################

main() {

    check_dependencies

    for entry in "${REPOS[@]}"
    do
        IFS='|' read -r repo folder <<< "$entry"

        install_release \
            "$repo" \
            "$folder"
    done

    echo
    log_info "Téléchargement terminé."
    echo
}

main "$@"