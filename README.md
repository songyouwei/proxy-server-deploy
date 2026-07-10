# Proxy Server Deploy

Caddy + NaiveProxy + VLESS (WebSocket via Xray-core) over HTTPS, one command.

## One-command Deploy

Default (prompts for domain/email/website directory — leave the directory blank for a placeholder page):

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo bash
```

With common options set explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo \
  WEB_DIR=/srv/www \
  ACME_EMAIL=admin@example.com \
  PROXY_DOMAIN=proxy.example.com \
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

To update to the latest releases and redeploy, just re-run the deploy command (with the same options you used initially).
