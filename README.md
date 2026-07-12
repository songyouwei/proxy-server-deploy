# Proxy Server Deploy

Caddy + NaiveProxy + VLESS (WebSocket via Xray-core) over HTTPS, one command.

NaiveProxy and VLESS+WebSocket need two separate domains (or subdomains), because only
VLESS+WebSocket can be fronted by a CDN to hide the origin IP:

- `PROXY_DOMAIN_NAIVE` — NaiveProxy connects directly, with no CDN in front (a CDN would
  break NaiveProxy's obfuscation), e.g. `direct.example.com`.
- `PROXY_DOMAIN_VLESS` — VLESS+WebSocket goes through a CDN (e.g. Cloudflare orange-cloud)
  to hide the origin IP, e.g. `example.com`. Served on both this domain and its `www.`
  subdomain.

Point `PROXY_DOMAIN_NAIVE` at the server's IP with the CDN disabled (grey-cloud in
Cloudflare), and point `PROXY_DOMAIN_VLESS`/`www.PROXY_DOMAIN_VLESS` at the server through
the CDN (orange-cloud in Cloudflare).

## One-command Deploy

Default (prompts for domains/email/website directory — leave the directory blank for a placeholder page):

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo bash
```

With common options set explicitly:

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

On success, the script prints your NaiveProxy and VLESS client URLs — the VLESS URL works with v2rayN/v2rayNG, Shadowrocket, Quantumult X, Clash Meta/Verge, sing-box, etc.

## Commands

```bash
cd /opt/proxy-server-deploy

sudo docker compose ps          # status
sudo docker compose logs -f     # logs
sudo docker compose restart     # restart after editing Caddyfile
```

## Updating

Once deployed, just re-run the deploy script with no options to pull the latest code and
redeploy:

```bash
cd /opt/proxy-server-deploy
sudo bash deploy.sh
```

Your existing Caddyfile, credentials, and `WEB_DIR` are detected and left as-is — they're
only touched again if you explicitly pass new values (or if the Caddyfile still looks like
the untouched placeholder, e.g. right after a fresh clone). The NaiveProxy and Xray images
are only rebuilt/pulled when a newer upstream release is available.

## Client Setup

This repo deploys the server; `clients/` holds companion scripts for connecting to it, kept
here because they parse the exact URL formats `deploy.sh` prints above — not the project's
main focus, just convenient for verifying a deploy end-to-end.

`clients/mac_client.sh` runs a NaiveProxy or VLESS client locally as a LaunchAgent — only one
at a time by default (both listen on the same local ports, so there's no need to run both).
Edit the `USER CONFIGURATION` section at the top: set `ACTIVE_PROXY` to `naive` or `vless`,
`NAIVE_PROXY` to your naiveproxy URL, and `VLESS_URL` to the `vless://...` URL printed above
by `deploy.sh`. Then:

```bash
./clients/mac_client.sh install     # installs and starts ACTIVE_PROXY
./clients/mac_client.sh status      # shows both, regardless of ACTIVE_PROXY
./clients/mac_client.sh restart vless   # switch: change ACTIVE_PROXY, then restart
```

See `./clients/mac_client.sh` (no args) for the full command list.
