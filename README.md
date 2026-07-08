# Proxy Server Deploy

Caddy + NaiveProxy over HTTPS, one command.

## Quick Start

With an existing website directory on the server (most deployments):

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo WEB_LOCAL_DIR=/srv/www bash
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

# Update to the latest forwardproxy release and redeploy
# (repeat any WEB_LOCAL_DIR etc. used for the initial deploy)
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo WEB_LOCAL_DIR=/srv/www bash
```
