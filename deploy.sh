#!/usr/bin/env bash

set -euo pipefail

DEFAULT_INSTALL_DIR="/opt/proxy-server-deploy"
DEFAULT_BRANCH="main"
DEFAULT_WEB_DIR="www"
DEFAULT_REPO_URL="https://github.com/songyouwei/proxy-server-deploy.git"

INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_URL="${REPO_URL:-$DEFAULT_REPO_URL}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
WEB_DIR="${WEB_DIR:-$DEFAULT_WEB_DIR}"
WEB_LOCAL_DIR="${WEB_LOCAL_DIR:-}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
AUTO_CONFIG="${AUTO_CONFIG:-auto}"
CLIENT_ENV_FILE="${CLIENT_ENV_FILE:-.deploy-client.env}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-.env}"
ACME_EMAIL="${ACME_EMAIL:-}"
PROXY_DOMAIN="${PROXY_DOMAIN:-}"
SITE_DOMAIN="${SITE_DOMAIN:-}"
NAIVE_USER="${NAIVE_USER:-proxy}"
NAIVE_PASSWORD="${NAIVE_PASSWORD:-}"
VMESS_UUID="${VMESS_UUID:-}"
WS_PATH="${WS_PATH:-/test}"

usage() {
    cat <<'EOF'
Usage:
  sudo bash deploy.sh [--repo <git-url>] [--branch <branch>] [--dir <install-dir>]

Examples:
  sudo PROXY_DOMAIN=proxy.example.com ACME_EMAIL=admin@example.com bash deploy.sh
  sudo PROXY_DOMAIN=proxy.example.com ACME_EMAIL=admin@example.com WEB_LOCAL_DIR=/srv/www bash deploy.sh

Environment:
  REPO_URL              Proxy deployment repository to clone or update. Default: https://github.com/songyouwei/proxy-server-deploy.git.
  BRANCH                Proxy deployment branch. Default: main.
  INSTALL_DIR           Target directory. Default: /opt/proxy-server-deploy.
  PROXY_DOMAIN          Required for automatic config. NaiveProxy HTTPS domain.
  SITE_DOMAIN           Optional website/V2Ray domain. Defaults to PROXY_DOMAIN.
  ACME_EMAIL            Required for automatic config. Caddy ACME email.
  NAIVE_USER            NaiveProxy username. Default: proxy.
  NAIVE_PASSWORD        NaiveProxy password. Auto-generated when empty.
  VMESS_UUID            V2Ray VMess UUID. Auto-generated when empty.
  WS_PATH               V2Ray WebSocket path. Default: /test.
  AUTO_CONFIG           auto, 1, or 0. Default: auto.
  CLIENT_ENV_FILE       Generated client values file. Default: .deploy-client.env.
  WEB_DIR               Default website directory relative to INSTALL_DIR. Default: www.
  WEB_LOCAL_DIR         Optional existing local website directory to mount as /var/www.
  SKIP_DOCKER_INSTALL   Set to 1 to skip Docker installation checks.
  FORCE_REBUILD         Set to 1 to rebuild the Caddy naiveproxy image.
  SKIP_FIREWALL_CONFIG  Set to 1 to skip automatic UFW 80/443 allow rules.
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

new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    fi
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

    if [ -n "$WEB_LOCAL_DIR" ]; then
        [ -d "$WEB_LOCAL_DIR" ] || die "WEB_LOCAL_DIR does not exist or is not a directory: $WEB_LOCAL_DIR"
        log "Using local website directory: $WEB_LOCAL_DIR"
        write_compose_env "$WEB_LOCAL_DIR"
        return
    fi

    mkdir -p "$WEB_DIR"
    if [ ! -f "$WEB_DIR/index.html" ]; then
        printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>hello</title></head><body>hello</body></html>' > "$WEB_DIR/index.html"
    fi

    write_compose_env "./$WEB_DIR"
}

write_compose_env() {
    cd "$INSTALL_DIR"

    local web_source="$1"
    local tmp_file
    tmp_file="$(mktemp)"

    if [ -f "$COMPOSE_ENV_FILE" ]; then
        grep -v '^WEB_SOURCE=' "$COMPOSE_ENV_FILE" > "$tmp_file" || true
    fi

    printf 'WEB_SOURCE=%s\n' "$web_source" >> "$tmp_file"
    mv "$tmp_file" "$COMPOSE_ENV_FILE"
}

has_placeholder_config() {
    grep -Eq 'proxy\.example\.com|site\.example\.com|00000000-0000-0000-0000-000000000000|change-this-password' Caddyfile config.json
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

write_generated_config() {
    cd "$INSTALL_DIR"

    if ! should_auto_configure; then
        return
    fi

    [ -n "$PROXY_DOMAIN" ] || die "PROXY_DOMAIN is required for automatic config"
    [ -n "$ACME_EMAIL" ] || die "ACME_EMAIL is required for automatic config"

    SITE_DOMAIN="${SITE_DOMAIN:-$PROXY_DOMAIN}"
    NAIVE_PASSWORD="${NAIVE_PASSWORD:-$(random_secret)}"
    VMESS_UUID="${VMESS_UUID:-$(new_uuid)}"

    log "Writing generated Caddyfile and config.json"

    if [ "$SITE_DOMAIN" = "$PROXY_DOMAIN" ]; then
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

  @v2ray_websocket {
    path ${WS_PATH}
    header Connection Upgrade
    header Upgrade websocket
  }
  reverse_proxy @v2ray_websocket 127.0.0.1:10000

  file_server {
    root /var/www
  }
}
EOF
    else
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

  file_server {
    root /var/www
    browse
  }
}

${SITE_DOMAIN} {
  @v2ray_websocket {
    path ${WS_PATH}
    header Connection Upgrade
    header Upgrade websocket
  }
  reverse_proxy @v2ray_websocket 127.0.0.1:10000

  file_server {
    root /var/www
  }
}
EOF
    fi

    cat > config.json <<EOF
{
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${VMESS_UUID}",
            "alterId": 0,
            "note": "generated-by-deploy"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

    chmod 600 Caddyfile config.json

    cat > "$CLIENT_ENV_FILE" <<EOF
PROXY_DOMAIN=${PROXY_DOMAIN}
SITE_DOMAIN=${SITE_DOMAIN}
NAIVE_USER=${NAIVE_USER}
NAIVE_PASSWORD=${NAIVE_PASSWORD}
VMESS_UUID=${VMESS_UUID}
WS_PATH=${WS_PATH}
EOF
    chmod 600 "$CLIENT_ENV_FILE"
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

    if [ -f "$CLIENT_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "./$CLIENT_ENV_FILE"
    fi

    log "Starting services"
    docker compose up -d
    docker compose ps

    if [ -n "$PROXY_DOMAIN" ]; then
        printf '\nProxy client values:\n'
        printf '  NaiveProxy URL: https://%s:%s@%s\n' "$NAIVE_USER" "$NAIVE_PASSWORD" "$PROXY_DOMAIN"
        printf '  VMess UUID: %s\n' "$VMESS_UUID"
        printf '  VMess host: %s\n' "$SITE_DOMAIN"
        printf '  VMess WebSocket path: %s\n\n' "$WS_PATH"
    fi

    log "Done. Check logs with: cd $INSTALL_DIR && docker compose logs -f"
}

main() {
    parse_args "$@"
    as_root
    install_packages
    install_docker
    configure_firewall
    sync_proxy_repo
    sync_web_repo
    write_generated_config
    validate_project
    build_image
    start_services
}

main "$@"
