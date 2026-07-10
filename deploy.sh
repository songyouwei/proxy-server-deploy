#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/proxy-server-deploy"
DEFAULT_BRANCH="main"
DEFAULT_WEB_DIR="www"
DEFAULT_REPO_URL="https://github.com/songyouwei/proxy-server-deploy.git"
DEFAULT_FORWARDPROXY_VERSION="v2.11.2-naive"
FORWARDPROXY_ASSET="caddy-forwardproxy-naive.tar.xz"
DEFAULT_XRAY_VERSION="26.3.27"

INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
WEB_DIR="${WEB_DIR:-$DEFAULT_WEB_DIR}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
AUTO_CONFIG="${AUTO_CONFIG:-auto}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-.env}"
ACME_EMAIL="${ACME_EMAIL:-}"
PROXY_DOMAIN="${PROXY_DOMAIN:-}"
NAIVE_USER="${NAIVE_USER:-proxy}"
NAIVE_PASSWORD="${NAIVE_PASSWORD:-}"
FORWARDPROXY_VERSION="${FORWARDPROXY_VERSION:-}"
XRAY_VERSION="${XRAY_VERSION:-}"
XRAY_UUID="${XRAY_UUID:-}"
XRAY_WS_PATH="${XRAY_WS_PATH:-}"
XRAY_PORT="${XRAY_PORT:-10086}"
GENERATED_CLIENT_INFO=0

usage() {
    cat <<'EOF'
Usage:
  sudo bash deploy.sh [--repo <git-url>] [--branch <branch>] [--dir <install-dir>]

Examples:
  sudo bash deploy.sh
  sudo PROXY_DOMAIN=proxy.example.com ACME_EMAIL=admin@example.com bash deploy.sh
  sudo PROXY_DOMAIN=proxy.example.com ACME_EMAIL=admin@example.com WEB_DIR=/srv/www bash deploy.sh

Environment:
  REPO_URL              Proxy deployment repository to clone or update. Default: https://github.com/songyouwei/proxy-server-deploy.git.
  BRANCH                Proxy deployment branch. Default: main.
  INSTALL_DIR           Target directory. Default: /opt/proxy-server-deploy.
  PROXY_DOMAIN          NaiveProxy HTTPS domain. Prompted when missing.
  ACME_EMAIL            Caddy ACME email. Prompted when missing.
  NAIVE_USER            NaiveProxy username. Default: proxy.
  NAIVE_PASSWORD        NaiveProxy password. Auto-generated when empty.
  AUTO_CONFIG           auto, 1, or 0. Default: auto.
  WEB_DIR               Website directory. A relative name is created under INSTALL_DIR
                        (with a placeholder page if empty); an absolute path mounts an
                        existing directory as-is. Default: www.
  SKIP_DOCKER_INSTALL   Set to 1 to skip Docker installation checks.
  FORCE_REBUILD         Set to 1 to rebuild the Caddy naiveproxy image.
  FORWARDPROXY_VERSION  klzgrad/forwardproxy release tag to build, e.g. v2.11.2-naive. Default: latest release with a caddy-forwardproxy-naive.tar.xz asset, detected automatically.
  XRAY_VERSION          XTLS/Xray-core release to pull for the VLESS+WebSocket service. Default: latest stable release, detected automatically.
  XRAY_PORT             Loopback port the Xray VLESS inbound listens on. Default: 10086.
  SKIP_FIREWALL_CONFIG  Set to 1 to skip automatic UFW 80/443 allow rules.
EOF
}

log() {
    printf '==> %s\n' "$*" >&2
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

prompt_into() {
    local name="$1"
    local prompt="$2"
    local value

    if ! { : < /dev/tty; } 2>/dev/null; then
        die "$name is required. Set it as an environment variable because no interactive terminal is available."
    fi

    while true; do
        printf '%s: ' "$prompt" > /dev/tty
        IFS= read -r value < /dev/tty || die "failed to read $name"
        if [ -n "$value" ]; then
            printf -v "$name" '%s' "$value"
            return
        fi
        printf '%s cannot be empty.\n' "$name" > /dev/tty
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

configure_firewall() {
    if [ "${SKIP_FIREWALL_CONFIG:-0}" = "1" ]; then
        log "Skipping firewall configuration"
        return
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        log "UFW not installed; skipping firewall configuration"
        return
    fi

    if ! ufw status | grep -qi '^Status: active'; then
        log "UFW is not active; skipping firewall configuration"
        return
    fi

    log "UFW is active; allowing inbound TCP 80 and 443"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload
}

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-'
    else
        date +%s%N | sha256sum | awk '{print $1}'
    fi
}

random_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    elif command -v openssl >/dev/null 2>&1; then
        local hex
        hex="$(openssl rand -hex 16)"
        printf '%s-%s-%s-%s-%s\n' \
            "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
    else
        date +%s%N | sha256sum | awk '{h=$1; print substr(h,1,8)"-"substr(h,9,4)"-"substr(h,13,4)"-"substr(h,17,4)"-"substr(h,21,12)}'
    fi
}

latest_forwardproxy_tag() {
    curl -fsSI "https://github.com/klzgrad/forwardproxy/releases/latest/download/${FORWARDPROXY_ASSET}" 2>/dev/null \
        | tr -d '\r' \
        | awk 'tolower($1) == "location:" {print $2}' \
        | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p'
}

latest_xray_tag() {
    curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/'
}

# $1: current value (may be empty), $2: label for logging, $3: fallback
# version, $4: name of a function that echoes the detected latest tag.
resolve_release_version() {
    local current="$1" label="$2" fallback="$3" detector="$4"
    if [ -z "$current" ]; then
        log "Detecting latest $label release"
        current="$("$detector")" || true
        if [ -n "$current" ]; then
            log "Using $label release $current"
        else
            current="$fallback"
            log "Could not detect latest $label release; falling back to $current"
        fi
    fi
    printf '%s' "$current"
}

resolve_forwardproxy_version() {
    FORWARDPROXY_VERSION="$(resolve_release_version "$FORWARDPROXY_VERSION" "klzgrad/forwardproxy" "$DEFAULT_FORWARDPROXY_VERSION" latest_forwardproxy_tag)"
    IMAGE_NAME="caddy-forwardproxy-naive:${FORWARDPROXY_VERSION}"
    export FORWARDPROXY_VERSION
}

resolve_xray_version() {
    XRAY_VERSION="$(resolve_release_version "$XRAY_VERSION" "XTLS/Xray-core" "$DEFAULT_XRAY_VERSION" latest_xray_tag)"
    XRAY_IMAGE="ghcr.io/xtls/xray-core:${XRAY_VERSION}"
    export XRAY_VERSION
}

running_from_project_dir() {
    [ -f "./deploy.sh" ] && [ -f "./build.sh" ]
}

set_aside_generated_files() {
    local f
    for f in Caddyfile docker-compose.yml; do
        if [ -f "$INSTALL_DIR/$f" ]; then
            mv "$INSTALL_DIR/$f" "$INSTALL_DIR/$f.pending"
            git -C "$INSTALL_DIR" rm --cached --quiet -- "$f" >/dev/null 2>&1 || true
        fi
    done
}

restore_generated_files() {
    local f
    for f in Caddyfile docker-compose.yml; do
        if [ -f "$INSTALL_DIR/$f.pending" ]; then
            mv "$INSTALL_DIR/$f.pending" "$INSTALL_DIR/$f"
        fi
    done
}

sync_proxy_repo() {
    if running_from_project_dir; then
        INSTALL_DIR="$(pwd)"
        log "Using current project directory: $INSTALL_DIR"
        return
    fi

    if [ -d "$INSTALL_DIR/.git" ]; then
        log "Updating proxy repository: $INSTALL_DIR"
        git -C "$INSTALL_DIR" fetch --all --prune
        set_aside_generated_files
        git -C "$INSTALL_DIR" checkout "$BRANCH"
        git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
        restore_generated_files
    else
        log "Cloning proxy repository into $INSTALL_DIR"
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi
}

sync_web_repo() {
    cd "$INSTALL_DIR"

    case "$WEB_DIR" in
        /*)
            [ -d "$WEB_DIR" ] || die "WEB_DIR does not exist or is not a directory: $WEB_DIR"
            log "Using local website directory: $WEB_DIR"
            write_compose_env "$WEB_DIR"
            ;;
        *)
            mkdir -p "$WEB_DIR"
            if [ ! -f "$WEB_DIR/index.html" ]; then
                printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>hello</title></head><body>hello</body></html>' > "$WEB_DIR/index.html"
            fi
            write_compose_env "./$WEB_DIR"
            ;;
    esac
}

write_compose_env() {
    cd "$INSTALL_DIR"

    local web_source="$1"
    local tmp_file
    tmp_file="$(mktemp)"

    if [ -f "$COMPOSE_ENV_FILE" ]; then
        grep -v '^WEB_DIR=' "$COMPOSE_ENV_FILE" > "$tmp_file" || true
    fi

    printf 'WEB_DIR=%s\n' "$web_source" >> "$tmp_file"
    mv "$tmp_file" "$COMPOSE_ENV_FILE"
}

has_placeholder_config() {
    [ ! -f Caddyfile ] || grep -Eq 'proxy\.example\.com|change-this-password' Caddyfile
}

should_auto_configure() {
    case "$AUTO_CONFIG" in
        1|true|yes)
            return 0
            ;;
        0|false|no)
            return 1
            ;;
        auto)
            has_placeholder_config
            return
            ;;
        *)
            die "AUTO_CONFIG must be auto, 1, or 0"
            ;;
    esac
}

prompt_config_inputs() {
    cd "$INSTALL_DIR"

    if ! should_auto_configure; then
        return
    fi

    if [ -z "$PROXY_DOMAIN" ]; then
        prompt_into PROXY_DOMAIN 'Proxy domain, for example proxy.example.com'
    fi

    if [ -z "$ACME_EMAIL" ]; then
        prompt_into ACME_EMAIL 'ACME email for TLS certificates'
    fi
}

validate_xray_uuid() {
    case "$1" in
        *[!A-Za-z0-9-]*|"") die "XRAY_UUID must be a non-empty string of letters, digits, and hyphens only (got: $1)" ;;
    esac
}

validate_xray_ws_path() {
    case "$1" in
        /*) ;;
        *) die "XRAY_WS_PATH must start with / (got: $1)" ;;
    esac
    case "$1" in
        *[!A-Za-z0-9/_-]*) die "XRAY_WS_PATH may only contain letters, digits, /, _, and - (got: $1)" ;;
    esac
}

# Writes xray/config.json from the current XRAY_UUID/XRAY_WS_PATH/XRAY_PORT.
# Caller is responsible for validating/deriving those first.
write_xray_config() {
    mkdir -p xray
    cat > xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${XRAY_UUID}", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${XRAY_WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
    # The xray container runs as root (see render_docker_compose) specifically
    # so this can stay owner-only instead of being world-readable.
    chmod 600 xray/config.json
}

# Existing installs from before VLESS/Xray support have a real Caddyfile but
# no xray/config.json yet. Provision just that piece in place instead of
# forcing a full AUTO_CONFIG=1 reconfigure, which would also rotate
# NAIVE_PASSWORD and break already-configured NaiveProxy clients.
backfill_xray_config() {
    [ -f xray/config.json ] && return

    XRAY_UUID="${XRAY_UUID:-$(random_uuid)}"
    XRAY_WS_PATH="${XRAY_WS_PATH:-/$(random_secret)}"
    validate_xray_uuid "$XRAY_UUID"
    validate_xray_ws_path "$XRAY_WS_PATH"

    log "No xray/config.json found; generating one for the VLESS+WebSocket service"
    write_xray_config

    local ws_path_encoded="${XRAY_WS_PATH//\//%2F}"
    printf '\nGenerated xray/config.json for VLESS+WebSocket (Caddyfile left untouched).\n'
    printf 'Add this line to the site block in %s/Caddyfile, above file_server, then run:\n' "$INSTALL_DIR"
    printf '  reverse_proxy %s 127.0.0.1:%s\n' "$XRAY_WS_PATH" "$XRAY_PORT"
    printf '  sudo docker compose restart\n'
    printf 'Once added, this is the client URL:\n'
    printf '  vless://%s@%s:443?encryption=none&security=tls&type=ws&host=%s&path=%s&sni=%s#%s\n\n' \
        "$XRAY_UUID" "$PROXY_DOMAIN" "$PROXY_DOMAIN" "$ws_path_encoded" "$PROXY_DOMAIN" "$PROXY_DOMAIN"
}

write_generated_config() {
    cd "$INSTALL_DIR"

    if ! should_auto_configure; then
        [ -f Caddyfile ] || die "AUTO_CONFIG=$AUTO_CONFIG requires an existing Caddyfile at $INSTALL_DIR/Caddyfile; provide one first, or unset AUTO_CONFIG to generate one automatically"
        backfill_xray_config
        return
    fi

    [ -n "$PROXY_DOMAIN" ] || die "PROXY_DOMAIN is required for automatic config"
    [ -n "$ACME_EMAIL" ] || die "ACME_EMAIL is required for automatic config"

    NAIVE_PASSWORD="${NAIVE_PASSWORD:-$(random_secret)}"
    XRAY_UUID="${XRAY_UUID:-$(random_uuid)}"
    XRAY_WS_PATH="${XRAY_WS_PATH:-/$(random_secret)}"
    validate_xray_uuid "$XRAY_UUID"
    validate_xray_ws_path "$XRAY_WS_PATH"

    log "Writing generated Caddyfile"

    cat > Caddyfile <<EOF
{
  order forward_proxy before file_server
  email ${ACME_EMAIL}
}

:443, ${PROXY_DOMAIN} {
  forward_proxy {
    basic_auth ${NAIVE_USER} ${NAIVE_PASSWORD}
    hide_ip
    hide_via
    probe_resistance
  }

  reverse_proxy ${XRAY_WS_PATH} 127.0.0.1:${XRAY_PORT}

  file_server {
    root /var/www
    browse
  }
}
EOF

    chmod 600 Caddyfile

    log "Writing generated Xray VLESS+WebSocket config"
    write_xray_config

    GENERATED_CLIENT_INFO=1
}

render_docker_compose() {
    cat <<EOF
services:
  naive:
    image: ${IMAGE_NAME}
    container_name: proxy-caddy-naive
    restart: always
    network_mode: host
    tty: true
    volumes:
      - ./Caddyfile:/etc/naiveproxy/Caddyfile:ro
      - ./data:/root/.local/share/caddy
      - \${WEB_DIR:-./www}:/var/www:ro
      - ./log:/var/log/caddy

  xray:
    image: ${XRAY_IMAGE}
    container_name: proxy-xray
    restart: always
    network_mode: host
    # Image defaults to a nonroot UID; run as root so it can read the
    # owner-only (600) bind-mounted config regardless of host UID mapping.
    user: "0:0"
    volumes:
      - ./xray:/usr/local/etc/xray:ro
EOF
}

write_docker_compose() {
    cd "$INSTALL_DIR"

    local generated
    generated="$(render_docker_compose)"

    if [ -f docker-compose.yml ] && [ "$(cat docker-compose.yml)" != "$generated" ]; then
        log "Existing docker-compose.yml differs from the generated template; backing up to docker-compose.yml.bak"
        cp docker-compose.yml docker-compose.yml.bak
    fi

    log "Writing docker-compose.yml"
    printf '%s\n' "$generated" > docker-compose.yml
}

validate_project() {
    cd "$INSTALL_DIR"

    [ -f docker-compose.yml ] || die "missing docker-compose.yml"
    [ -f Caddyfile ] || die "missing Caddyfile"
    [ -f xray/config.json ] || die "missing xray/config.json"
    [ -f build.sh ] || die "missing build.sh"

    mkdir -p data log
    chmod +x build.sh
}

build_image() {
    cd "$INSTALL_DIR"

    if [ "$FORCE_REBUILD" != "1" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        log "Docker image already exists: $IMAGE_NAME"
        return
    fi

    log "Building $IMAGE_NAME"
    ./build.sh
}

start_services() {
    cd "$INSTALL_DIR"

    log "Starting services"
    docker compose up -d --remove-orphans
    # Caddyfile/docker-compose.yml are bind-mounted; up -d only recreates a
    # container when the compose config itself changes, not the mounted
    # file's content, so restart unconditionally to pick up edits.
    docker compose restart
    docker compose ps

    if [ "$GENERATED_CLIENT_INFO" = "1" ]; then
        # Only printed right after auto-generating the Caddyfile: once you
        # hand-edit it (e.g. multiple basic_auth users), there's no single
        # canonical credential left to re-derive on later runs.
        local ws_path_encoded="${XRAY_WS_PATH//\//%2F}"
        printf '\nProxy client values:\n'
        printf '  NaiveProxy URL: https://%s:%s@%s\n' "$NAIVE_USER" "$NAIVE_PASSWORD" "$PROXY_DOMAIN"
        printf '  VLESS URL: vless://%s@%s:443?encryption=none&security=tls&type=ws&host=%s&path=%s&sni=%s#%s\n' \
            "$XRAY_UUID" "$PROXY_DOMAIN" "$PROXY_DOMAIN" "$ws_path_encoded" "$PROXY_DOMAIN" "$PROXY_DOMAIN"
        printf '\n'
    fi

    log "Done. Check logs with: cd $INSTALL_DIR && docker compose logs -f"
}

main() {
    parse_args "$@"
    as_root
    install_packages
    resolve_forwardproxy_version
    resolve_xray_version
    sync_proxy_repo
    prompt_config_inputs
    install_docker
    configure_firewall
    sync_web_repo
    write_generated_config
    write_docker_compose
    validate_project
    build_image
    start_services
}

main "$@"
