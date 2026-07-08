# Proxy Server Deploy

Caddy + NaiveProxy over HTTPS, one command.

## Quick Start

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

# Restart after config changes
sudo docker compose up -d
```
