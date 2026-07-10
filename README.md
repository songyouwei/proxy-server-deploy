# Proxy Server Deploy

Caddy + NaiveProxy + VLESS(WebSocket via Xray-core) over HTTPS, one command.

Caddy terminates TLS for both protocols on the same domain: NaiveProxy via the `forward_proxy` plugin, and VLESS+WebSocket reverse-proxied to a local Xray-core container on a random path. The VLESS route has no protocol-specific TLS of its own, so it can later sit behind a CDN (e.g. Cloudflare orange-cloud) to hide the origin IP — NaiveProxy cannot, since CDNs don't forward its CONNECT tunneling.

## Quick Start

With an existing website directory on the server (most deployments):

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo WEB_DIR=/srv/www bash
```

Without one, a placeholder page is generated:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo bash
```

## Commands

```bash
cd /opt/proxy-server-deploy

# Status
sudo docker compose ps

# Logs
sudo docker compose logs -f

# Restart after editing Caddyfile
sudo docker compose restart

# Update to the latest forwardproxy/Xray-core releases and redeploy
# (repeat any WEB_DIR etc. used for the initial deploy)
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo WEB_DIR=/srv/www bash
```

On first deploy (or any time `AUTO_CONFIG=1` is set), the script prints both client values once:

```
Proxy client values:
  NaiveProxy URL: https://proxy:<password>@proxy.example.com
  VLESS URL: vless://<uuid>@proxy.example.com:443?encryption=none&security=tls&type=ws&host=proxy.example.com&path=%2F<random>&sni=proxy.example.com#proxy.example.com
```

The VLESS URL works with v2rayN/v2rayNG, Shadowrocket, Quantumult X, Clash Meta/Verge, sing-box, etc.

Upgrading an install that predates VLESS support doesn't touch your existing Caddyfile or NaiveProxy password: it generates `xray/config.json` and prints the one `reverse_proxy` line to add to your Caddyfile (plus the resulting VLESS URL) instead of auto-editing a file you may have hand-customized.
