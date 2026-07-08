#!/usr/bin/env bash

set -euo pipefail

DEFAULT_FORWARDPROXY_VERSION="v2.11.2-naive"
FORWARDPROXY_ASSET="caddy-forwardproxy-naive.tar.xz"

latest_forwardproxy_tag() {
    curl -fsSI "https://github.com/klzgrad/forwardproxy/releases/latest/download/${FORWARDPROXY_ASSET}" 2>/dev/null \
        | tr -d '\r' \
        | awk 'tolower($1) == "location:" {print $2}' \
        | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p'
}

FORWARDPROXY_VERSION="${FORWARDPROXY_VERSION:-}"
if [ -z "$FORWARDPROXY_VERSION" ]; then
    echo "==> Detecting latest klzgrad/forwardproxy release with a $FORWARDPROXY_ASSET asset..."
    FORWARDPROXY_VERSION="$(latest_forwardproxy_tag)" || true
    if [ -n "$FORWARDPROXY_VERSION" ]; then
        echo "==> Using forwardproxy release $FORWARDPROXY_VERSION"
    else
        FORWARDPROXY_VERSION="$DEFAULT_FORWARDPROXY_VERSION"
        echo "==> Could not detect latest forwardproxy release; falling back to $FORWARDPROXY_VERSION"
    fi
fi
RELEASE_URL="${RELEASE_URL:-https://github.com/klzgrad/forwardproxy/releases/download/${FORWARDPROXY_VERSION}/${FORWARDPROXY_ASSET}}"
ASSET="$FORWARDPROXY_ASSET"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
IMAGE_NAME="${IMAGE_NAME:-caddy-forwardproxy-naive:${FORWARDPROXY_VERSION}}"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Downloading Caddy naiveproxy release..."
curl -fL "$RELEASE_URL" -o "$ASSET"

echo "==> Extracting release asset..."
tar -xJf "$ASSET"
rm "$ASSET"

echo "==> Locating caddy binary..."
CADDY_PATH="$(find . -type f -name caddy | head -n 1)"

if [ -z "$CADDY_PATH" ]; then
    echo "Error: Caddy binary not found in extracted archive" >&2
    exit 1
fi

echo "==> Found caddy at: $CADDY_PATH"
mv "$CADDY_PATH" ./caddy
chmod +x ./caddy

echo "==> Writing Dockerfile..."
cat > Dockerfile <<'EOF'
FROM alpine:latest

RUN apk add --no-cache ca-certificates

COPY caddy /usr/bin/caddy

RUN mkdir -p /etc/naiveproxy /var/www /var/log/caddy

WORKDIR /etc/naiveproxy

EXPOSE 80 443

ENTRYPOINT ["/usr/bin/caddy", "run", "--config", "/etc/naiveproxy/Caddyfile", "--adapter", "caddyfile"]
EOF

echo "==> Building Docker image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" .

echo "==> Build completed successfully!"
