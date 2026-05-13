# Proxy Server Deploy

Generic Docker Compose deployment for a proxy server stack:

- Caddy with `forwardproxy-naive` for NaiveProxy over HTTPS.
- V2Ray VMess over WebSocket behind Caddy.
- Optional static web content from a separate Git repository.

This repository intentionally does not include certificates, runtime data, logs, or website files.

## Quick Start

Fork or copy this repository, then edit:

- `Caddyfile`: domains, email, NaiveProxy users.
- `config.json`: VMess UUIDs and WebSocket path.

Deploy on a new server:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo REPO_URL=https://github.com/songyouwei/proxy-server-deploy.git bash
```

Deploy with website files from a separate repository:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo REPO_URL=https://github.com/songyouwei/proxy-server-deploy.git WEB_REPO_URL=https://github.com/yourname/your-static-site.git bash
```

The website repository is cloned into `www/` at deploy time. It stays separate from this proxy deployment repository.

## Runtime Layout

```text
/opt/proxy-server-deploy/
  Caddyfile
  config.json
  docker-compose.yml
  data/     # Caddy certificates and runtime state, ignored by Git
  log/      # Caddy logs, ignored by Git
  www/      # optional separate website checkout, ignored by Git
```

## Configuration Notes

The default `Caddyfile` uses placeholder domains. Replace them before deployment:

- `proxy.example.com`: NaiveProxy endpoint.
- `site.example.com`: static site and V2Ray WebSocket host.

The default V2Ray WebSocket path is `/test`. If you change it in `config.json`, also change it in `Caddyfile`.

Ports `80` and `443` must be open, and all configured domains must resolve to the server before Caddy can issue TLS certificates.

## Commands

Check status:

```bash
cd /opt/proxy-server-deploy
sudo docker compose ps
```

Follow logs:

```bash
cd /opt/proxy-server-deploy
sudo docker compose logs -f
```

Restart after config changes:

```bash
cd /opt/proxy-server-deploy
sudo docker compose up -d
```

Update the proxy repo and website repo:

```bash
cd /opt/proxy-server-deploy
sudo REPO_URL=https://github.com/songyouwei/proxy-server-deploy.git WEB_REPO_URL=https://github.com/yourname/your-static-site.git ./deploy.sh
```
