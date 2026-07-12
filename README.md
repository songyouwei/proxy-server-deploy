# Proxy Server Deploy

Caddy + NaiveProxy + VLESS (WebSocket via Xray-core) over HTTPS, one command.

## Deploy

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo bash
```

Prompts for two domains, an ACME email, and a website directory (leave the directory blank
for a placeholder page):

- `PROXY_DOMAIN_NAIVE` — NaiveProxy, connected to directly with no CDN (a CDN would break its
  obfuscation), e.g. `direct.example.com`. Point it at the server's IP with the CDN disabled
  (grey-cloud in Cloudflare).
- `PROXY_DOMAIN_VLESS` — VLESS+WebSocket, fronted by a CDN to hide the origin IP (orange-cloud
  in Cloudflare), e.g. `example.com`. Served on both this domain and its `www.` subdomain.

Or set everything non-interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo \
  WEB_DIR=/srv/www \
  ACME_EMAIL=admin@example.com \
  PROXY_DOMAIN_VLESS=example.com \
  PROXY_DOMAIN_NAIVE=direct.example.com \
  NAIVE_USER=proxy \
  NAIVE_PASSWORD=changeme \
  bash
```

On success it prints your NaiveProxy and VLESS client URLs — the VLESS URL works with
v2rayN/v2rayNG, Shadowrocket, Quantumult X, Clash Meta/Verge, sing-box, etc.

## Commands

```bash
cd /opt/proxy-server-deploy

sudo docker compose ps          # status
sudo docker compose logs -f     # logs
sudo docker compose restart     # restart after editing Caddyfile
```

## Updating

```bash
cd /opt/proxy-server-deploy
sudo bash deploy.sh
```

Re-running with no options pulls the latest code and redeploys. Your existing Caddyfile,
credentials, and `WEB_DIR` are left as-is unless you pass new values.

## Clients

`clients/` holds companion scripts for connecting to a deployed server — e.g.
`clients/mac_client.sh` runs a NaiveProxy or VLESS client on macOS as a LaunchAgent. Run it
with no arguments for usage.
