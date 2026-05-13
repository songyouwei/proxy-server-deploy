#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/proxy-server-deploy"
DEFAULT_BRANCH="main"
DEFAULT_WEB_DIR="www"

INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
WEB_REPO_URL="${WEB_REPO_URL:-}"
WEB_BRANCH="${WEB_BRANCH:-main}"
WEB_DIR="${WEB_DIR:-$DEFAULT_WEB_DIR}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

usage() {
    cat <<'EOF'
Usage:
  sudo bash deploy.sh [--repo <git-url>] [--branch <branch>] [--dir <install-dir>]

Examples:
  sudo REPO_URL=https://github.com/songyouwei/proxy-server-deploy.git bash deploy.sh
  sudo REPO_URL=https://github.com/songyouwei/proxy-server-deploy.git WEB_REPO_URL=https://github.com/yourname/site.git bash deploy.sh

Environment:
  REPO_URL              Proxy deployment repository to clone or update.
  BRANCH                Proxy deployment branch. Default: main.
  INSTALL_DIR           Target directory. Default: /opt/proxy-server-deploy.
  WEB_REPO_URL          Optional separate static website repository.
  WEB_BRANCH            Website repository branch. Default: main.
  WEB_DIR               Website checkout path relative to INSTALL_DIR. Default: www.
  SKIP_DOCKER_INSTALL   Set to 1 to skip Docker installation checks.
  FORCE_REBUILD         Set to 1 to rebuild the Caddy naiveproxy image.
EOF
}

log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

as_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "please run as root, for example: sudo bash deploy.sh"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo)
                REPO_URL="${2:-}"
                shift 2
                ;;
            --branch)
                BRANCH="${2:-}"
                shift 2
                ;;
            --dir)
                INSTALL_DIR="${2:-}"
                shift 2
                ;;
            --web-repo)
                WEB_REPO_URL="${2:-}"
                shift 2
                ;;
            --web-branch)
                WEB_BRANCH="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y ca-certificates curl git xz-utils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl git xz
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl git xz
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl git xz
    else
        die "unsupported Linux distribution: install curl, git, and xz-utils manually"
    fi
}

install_docker() {
    if [ "$SKIP_DOCKER_INSTALL" = "1" ]; then
        return
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Docker and Docker Compose are already installed"
        return
    fi

    log "Installing Docker"
    curl -fsSL https://get.docker.com | sh

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
        service docker start || true
    fi

    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable after Docker installation"
}

running_from_project_dir() {
    [ -f "./docker-compose.yml" ] && [ -f "./Caddyfile" ] && [ -f "./config.json" ] && [ -f "./build.sh" ]
}

sync_proxy_repo() {
    if running_from_project_dir; then
        INSTALL_DIR="$(pwd)"
        log "Using current project directory: $INSTALL_DIR"
        return
    fi

    [ -n "$REPO_URL" ] || die "REPO_URL is required when deploy.sh is not run from the project directory"

    if [ -d "$INSTALL_DIR/.git" ]; then
        log "Updating proxy repository: $INSTALL_DIR"
        git -C "$INSTALL_DIR" fetch --all --prune
        git -C "$INSTALL_DIR" checkout "$BRANCH"
        git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
    else
        log "Cloning proxy repository into $INSTALL_DIR"
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi
}

sync_web_repo() {
    cd "$INSTALL_DIR"

    if [ -z "$WEB_REPO_URL" ]; then
        mkdir -p "$WEB_DIR"
        if [ ! -f "$WEB_DIR/index.html" ]; then
            printf '%s\n' '<!doctype html><title>proxy server</title><h1>proxy server</h1>' > "$WEB_DIR/index.html"
        fi
        return
    fi

    if [ -d "$WEB_DIR/.git" ]; then
        log "Updating website repository: $WEB_DIR"
        git -C "$WEB_DIR" fetch --all --prune
        git -C "$WEB_DIR" checkout "$WEB_BRANCH"
        git -C "$WEB_DIR" pull --ff-only origin "$WEB_BRANCH"
    else
        if [ -e "$WEB_DIR" ] && [ "$(find "$WEB_DIR" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
            die "$WEB_DIR exists and is not empty; move it away or set WEB_DIR to another path"
        fi
        rm -rf "$WEB_DIR"
        log "Cloning website repository into $WEB_DIR"
        git clone --branch "$WEB_BRANCH" "$WEB_REPO_URL" "$WEB_DIR"
    fi
}

validate_project() {
    cd "$INSTALL_DIR"

    [ -f docker-compose.yml ] || die "missing docker-compose.yml"
    [ -f Caddyfile ] || die "missing Caddyfile"
    [ -f config.json ] || die "missing config.json"
    [ -f build.sh ] || die "missing build.sh"

    mkdir -p data log
    chmod +x build.sh
}

build_image() {
    cd "$INSTALL_DIR"

    if [ "$FORCE_REBUILD" != "1" ] && docker image inspect caddy-forwardproxy-naive:v2.10.0 >/dev/null 2>&1; then
        log "Docker image already exists: caddy-forwardproxy-naive:v2.10.0"
        return
    fi

    log "Building caddy-forwardproxy-naive:v2.10.0"
    ./build.sh
}

start_services() {
    cd "$INSTALL_DIR"

    log "Starting services"
    docker compose up -d
    docker compose ps

    log "Done. Check logs with: cd $INSTALL_DIR && docker compose logs -f"
}

main() {
    parse_args "$@"
    as_root
    install_packages
    install_docker
    sync_proxy_repo
    sync_web_repo
    validate_project
    build_image
    start_services
}

main "$@"
