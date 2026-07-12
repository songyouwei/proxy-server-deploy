#!/usr/bin/env bash
set -euo pipefail

### =========================
### USER CONFIGURATION
### =========================

# Which proxy to actually run day-to-day. Only one is needed at a time, so
# both listen on the same local ports below — switch with:
#   ./mac_client.sh restart naive   (or vless)
# Pass an explicit "naive"/"vless"/"all" as the 2nd CLI arg to override this.
ACTIVE_PROXY="naive"

# --- NaiveProxy ---
NAIVE_LISTEN_SOCKS="socks://127.0.0.1:1080"
NAIVE_LISTEN_HTTP="http://127.0.0.1:1081"
NAIVE_PROXY="https://user:pass@direct.example.com"

# --- VLESS (via Xray-core) ---
# Paste the full "vless://..." URL printed by deploy.sh on the server here.
# Everything (uuid, host, port, ws path, sni) is parsed out of it.
VLESS_URL="vless://uuid@example.com:443?encryption=none&security=tls&type=ws&path=%2Fpath"
VLESS_LISTEN_SOCKS="socks://127.0.0.1:1080"
VLESS_LISTEN_HTTP="http://127.0.0.1:1081"

### =========================
### INTERNAL VARIABLES
### =========================

NAIVE_LABEL="com.naiveproxy.local"
VLESS_LABEL="com.vlessproxy.local"

NAIVE_INSTALL_DIR="$HOME/.naiveproxy"
VLESS_INSTALL_DIR="$HOME/.vlessproxy"

NAIVE_BIN="$NAIVE_INSTALL_DIR/naive"
VLESS_BIN="$VLESS_INSTALL_DIR/xray"

NAIVE_PLIST="$HOME/Library/LaunchAgents/$NAIVE_LABEL.plist"
VLESS_PLIST="$HOME/Library/LaunchAgents/$VLESS_LABEL.plist"

NAIVE_REPO="klzgrad/naiveproxy"
NAIVE_ARCH="mac-arm64"

XRAY_REPO="XTLS/Xray-core"
XRAY_ASSET="Xray-macos-arm64-v8a.zip"

### =========================
### HELPERS
### =========================

die() {
    echo "❌ $*" >&2
    exit 1
}

info() {
    echo "▶ $*"
}

url_decode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

### =========================
### NAIVEPROXY (NaiveProxy client)
### =========================

naive_latest_release_url() {
    curl -fsSL "https://api.github.com/repos/$NAIVE_REPO/releases/latest" \
        | grep browser_download_url \
        | grep "$NAIVE_ARCH.tar.xz" \
        | cut -d '"' -f 4
}

naive_install() {
    mkdir -p "$NAIVE_INSTALL_DIR"

    info "Fetching latest naiveproxy release…"
    local url
    # The || true keeps a pipeline failure (e.g. network hiccup, GitHub API
    # rate limit) from tripping `set -e` right here and killing the script
    # before the friendlier die() below gets a chance to run.
    url="$(naive_latest_release_url)" || true
    [[ -n "$url" ]] || die "Failed to detect latest naiveproxy release (network issue or GitHub API rate limit?)"

    local tmp tar
    tmp="$(mktemp -d)"
    tar="$tmp/naiveproxy.tar.xz"

    info "Downloading $url"
    curl -L "$url" -o "$tar"

    info "Extracting…"
    tar -xJf "$tar" -C "$tmp"

    local bin_path
    bin_path="$(find "$tmp" -name naive -type f | head -n1)"
    [[ -x "$bin_path" ]] || die "naive binary not found"

    mv "$bin_path" "$NAIVE_BIN"
    chmod +x "$NAIVE_BIN"
    rm -rf "$tmp"

    info "Installed naiveproxy to $NAIVE_BIN"
}

naive_create_plist() {
    mkdir -p "$NAIVE_INSTALL_DIR"
    info "Creating NaiveProxy LaunchAgent plist…"

    cat > "$NAIVE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$NAIVE_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$NAIVE_BIN</string>
        <string>--listen=$NAIVE_LISTEN_SOCKS</string>
        <string>--listen=$NAIVE_LISTEN_HTTP</string>
        <string>--proxy=$NAIVE_PROXY</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$NAIVE_INSTALL_DIR/naiveproxy.log</string>

    <key>StandardErrorPath</key>
    <string>$NAIVE_INSTALL_DIR/naiveproxy.err</string>
</dict>
</plist>
EOF
}

naive_start() {
    [[ -x "$NAIVE_BIN" ]] || die "naiveproxy is not installed; run: $0 install naive"
    naive_create_plist
    launchctl unload "$NAIVE_PLIST" >/dev/null 2>&1 || true
    launchctl load "$NAIVE_PLIST"
    info "naiveproxy started"
}

naive_stop() {
    launchctl unload "$NAIVE_PLIST" >/dev/null 2>&1 || true
    info "naiveproxy stopped"
}

naive_status() {
    echo "▶ naiveproxy status"

    if [[ -x "$NAIVE_BIN" ]]; then
        local version
        version="$("$NAIVE_BIN" --version 2>/dev/null || true)"
        echo "  Version : ${version:-unknown}"
    else
        echo "  Version : not installed"
    fi

    if launchctl print "gui/$(id -u)/$NAIVE_LABEL" >/dev/null 2>&1; then
        echo "  Service : running"
        launchctl print "gui/$(id -u)/$NAIVE_LABEL" \
            | awk '/pid =/ {print "  PID     : " $3}'
    else
        echo "  Service : NOT running"
    fi
}

naive_uninstall() {
    info "Uninstalling naiveproxy…"
    launchctl unload "$NAIVE_PLIST" >/dev/null 2>&1 || true

    if [[ -f "$NAIVE_PLIST" ]]; then
        rm -f "$NAIVE_PLIST"
        info "Removed LaunchAgent plist"
    fi

    if [[ -d "$NAIVE_INSTALL_DIR" ]]; then
        rm -rf "$NAIVE_INSTALL_DIR"
        info "Removed $NAIVE_INSTALL_DIR"
    fi

    info "naiveproxy uninstalled successfully"
}

### =========================
### VLESS (Xray-core client)
### =========================

# Parses $VLESS_URL into VLESS_UUID, VLESS_ADDRESS, VLESS_PORT, VLESS_WS_HOST,
# VLESS_WS_PATH, VLESS_SNI.
vless_parse_url() {
    local url="$VLESS_URL"
    [[ "$url" == vless://* ]] || die "VLESS_URL must start with vless://"
    url="${url#vless://}"
    url="${url%%#*}"

    VLESS_UUID="${url%%@*}"
    local rest="${url#*@}"

    local hostport="${rest%%\?*}"
    VLESS_ADDRESS="${hostport%%:*}"
    VLESS_PORT="${hostport##*:}"
    [[ -n "$VLESS_UUID" && -n "$VLESS_ADDRESS" && -n "$VLESS_PORT" ]] \
        || die "Failed to parse uuid/host/port from VLESS_URL"

    VLESS_WS_HOST="$VLESS_ADDRESS"
    VLESS_WS_PATH="/"
    VLESS_SNI="$VLESS_ADDRESS"

    local query="${rest#*\?}"
    local kv key val
    IFS='&' read -ra pairs <<< "$query"
    for kv in "${pairs[@]}"; do
        key="${kv%%=*}"
        val="$(url_decode "${kv#*=}")"
        case "$key" in
            host) VLESS_WS_HOST="$val" ;;
            path) VLESS_WS_PATH="$val" ;;
            sni) VLESS_SNI="$val" ;;
        esac
    done
}

vless_latest_release_url() {
    curl -fsSL "https://api.github.com/repos/$XRAY_REPO/releases/latest" \
        | grep browser_download_url \
        | grep -F "$XRAY_ASSET" \
        | grep -v '\.dgst"' \
        | cut -d '"' -f 4
}

vless_install() {
    mkdir -p "$VLESS_INSTALL_DIR"

    info "Fetching latest Xray-core release…"
    local url
    # See the matching comment in naive_install(): without || true, a failed
    # pipeline here trips `set -e` before the die() below can run.
    url="$(vless_latest_release_url)" || true
    [[ -n "$url" ]] || die "Failed to detect latest Xray-core release (network issue or GitHub API rate limit?)"

    local tmp zip
    tmp="$(mktemp -d)"
    zip="$tmp/xray.zip"

    info "Downloading $url"
    curl -L "$url" -o "$zip"

    info "Extracting…"
    unzip -qq -o "$zip" -d "$tmp"

    local bin_path
    bin_path="$(find "$tmp" -name xray -type f | head -n1)"
    [[ -n "$bin_path" ]] || die "xray binary not found"

    mv "$bin_path" "$VLESS_BIN"
    chmod +x "$VLESS_BIN"
    rm -rf "$tmp"

    info "Installed Xray-core to $VLESS_BIN"
}

vless_listen_port() {
    # Extracts the port from a "socks://127.0.0.1:1082"-style URL.
    echo "${1##*:}"
}

vless_write_config() {
    vless_parse_url
    mkdir -p "$VLESS_INSTALL_DIR"

    local socks_port http_port
    socks_port="$(vless_listen_port "$VLESS_LISTEN_SOCKS")"
    http_port="$(vless_listen_port "$VLESS_LISTEN_HTTP")"

    info "Writing Xray client config…"
    cat > "$VLESS_INSTALL_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${socks_port},
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    },
    {
      "listen": "127.0.0.1",
      "port": ${http_port},
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${VLESS_ADDRESS}",
            "port": ${VLESS_PORT},
            "users": [
              { "id": "${VLESS_UUID}", "encryption": "none" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${VLESS_SNI}"
        },
        "wsSettings": {
          "path": "${VLESS_WS_PATH}",
          "headers": {
            "Host": "${VLESS_WS_HOST}"
          }
        }
      }
    },
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF
    chmod 600 "$VLESS_INSTALL_DIR/config.json"
}

vless_create_plist() {
    info "Creating VLESS LaunchAgent plist…"

    cat > "$VLESS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$VLESS_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$VLESS_BIN</string>
        <string>run</string>
        <string>-config</string>
        <string>$VLESS_INSTALL_DIR/config.json</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$VLESS_INSTALL_DIR/vlessproxy.log</string>

    <key>StandardErrorPath</key>
    <string>$VLESS_INSTALL_DIR/vlessproxy.err</string>
</dict>
</plist>
EOF
}

vless_start() {
    [[ -x "$VLESS_BIN" ]] || die "Xray-core is not installed; run: $0 install vless"
    vless_write_config
    vless_create_plist
    launchctl unload "$VLESS_PLIST" >/dev/null 2>&1 || true
    launchctl load "$VLESS_PLIST"
    info "vlessproxy started"
}

vless_stop() {
    launchctl unload "$VLESS_PLIST" >/dev/null 2>&1 || true
    info "vlessproxy stopped"
}

vless_status() {
    echo "▶ vlessproxy status"

    if [[ -x "$VLESS_BIN" ]]; then
        local version
        version="$("$VLESS_BIN" version 2>/dev/null | head -n1 || true)"
        echo "  Version : ${version:-unknown}"
    else
        echo "  Version : not installed"
    fi

    if launchctl print "gui/$(id -u)/$VLESS_LABEL" >/dev/null 2>&1; then
        echo "  Service : running"
        launchctl print "gui/$(id -u)/$VLESS_LABEL" \
            | awk '/pid =/ {print "  PID     : " $3}'
    else
        echo "  Service : NOT running"
    fi
}

vless_uninstall() {
    info "Uninstalling vlessproxy…"
    launchctl unload "$VLESS_PLIST" >/dev/null 2>&1 || true

    if [[ -f "$VLESS_PLIST" ]]; then
        rm -f "$VLESS_PLIST"
        info "Removed LaunchAgent plist"
    fi

    if [[ -d "$VLESS_INSTALL_DIR" ]]; then
        rm -rf "$VLESS_INSTALL_DIR"
        info "Removed $VLESS_INSTALL_DIR"
    fi

    info "vlessproxy uninstalled successfully"
}

### =========================
### COMMAND DISPATCH
### =========================

cmd="${1:-}"
# naive and vless share the same local ports (only one is meant to run at a
# time), so install/start/restart always act on a single target — default
# ACTIVE_PROXY, or an explicit "naive"/"vless" override. stop/uninstall/status
# don't bind any ports, so they just always act on both, unconditionally.
target="${2:-$ACTIVE_PROXY}"

# Calls naive_$1 or vless_$1 depending on $target. Dispatches directly
# (not via command substitution) so a bad $target's die() actually aborts
# the script instead of just exiting a subshell.
call_target() {
    case "$target" in
        naive) "naive_$1" ;;
        vless) "vless_$1" ;;
        *) die "unknown target: $target (expected naive or vless)" ;;
    esac
}

# Stops the proxy that ISN'T the target, so it's never left running
# alongside it.
stop_other() {
    case "$target" in
        naive) vless_stop ;;
        vless) naive_stop ;;
    esac
}

case "$cmd" in
    install|upgrade)
        stop_other
        call_target stop
        call_target install
        call_target start
        ;;
    start)
        stop_other
        call_target start
        ;;
    stop)
        naive_stop
        vless_stop
        ;;
    restart)
        stop_other
        call_target stop
        call_target start
        ;;
    status)
        naive_status
        vless_status
        ;;
    uninstall)
        naive_uninstall
        vless_uninstall
        ;;
    *)
        cat <<EOF
Usage: $0 {install|upgrade|start|stop|restart|status|uninstall} [naive|vless]

Commands:
  install | upgrade   Download latest release and start (target only)
  start               Start LaunchAgent (target only)
  stop                Stop both LaunchAgents
  restart             Restart (target only)
  status              Show running status and version for both
  uninstall           Stop and remove all files for both

Target (default: \$ACTIVE_PROXY, currently "$ACTIVE_PROXY"):
  Only used by install/start/restart, since naive and vless share the same
  local ports and only one is meant to run at a time. Whichever one you
  target, the other is stopped first automatically.

Switch which proxy you use day-to-day by changing ACTIVE_PROXY at the top
of this script, then: ./mac_client.sh restart

Config:
  NaiveProxy install dir : $NAIVE_INSTALL_DIR
  VLESS install dir      : $VLESS_INSTALL_DIR

Before running, edit the USER CONFIGURATION section at the top of this
script: set NAIVE_PROXY to your naiveproxy URL, and VLESS_URL to the
"vless://..." URL printed by deploy.sh on the server.
EOF
        exit 1
        ;;
esac
