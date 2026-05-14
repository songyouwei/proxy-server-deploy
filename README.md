# Proxy Server Deploy

Generic Docker Compose deployment for a proxy server stack:

- Caddy with `forwardproxy-naive` for NaiveProxy over HTTPS.
- V2Ray VMess over WebSocket behind Caddy.
- Optional static web content from an existing local directory.

This repository intentionally does not include certificates, runtime data, logs, or website files.

## Quick Start

The deploy script is non-interactive. It can generate `Caddyfile` and `config.json` from environment variables on the target server.
If `ufw` is active, it also opens inbound TCP `80` and `443` automatically.
The generated NaiveProxy Caddy site address includes `:443, PROXY_DOMAIN` so the forward proxy is available on the HTTPS listener.

Deploy only the proxy stack, with a generated placeholder website:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo PROXY_DOMAIN=proxy.example.com ACME_EMAIL=admin@example.com bash
```

Recommended for real websites: deploy with an existing local website directory on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/songyouwei/proxy-server-deploy/main/deploy.sh | sudo PROXY_DOMAIN=proxy.example.com ACME_EMAIL=admin@example.com WEB_LOCAL_DIR=/srv/www bash
```

`WEB_LOCAL_DIR` is mounted read-only as `/var/www` inside the Caddy container. This is the preferred path for larger website exports, rsync-managed content, backup restores, or content maintained outside GitHub.

Example website layout:

```text
/srv/www/
  index.html
  assets/
  www.example.com/
```

The deploy script writes `WEB_SOURCE=/srv/www` into `.env` for Docker Compose, so later `docker compose up -d` keeps using the same local directory.

If `NAIVE_PASSWORD` or `VMESS_UUID` are not provided, the script generates them and prints the client values after deployment.
Those generated values are also stored on the server in `.deploy-client.env`, which is ignored by Git.

## Runtime Layout

```text
/opt/proxy-server-deploy/
  Caddyfile
  config.json
  docker-compose.yml
  data/     # Caddy certificates and runtime state, ignored by Git
  log/      # Caddy logs, ignored by Git
  www/      # default generated website directory, ignored by Git
  .env      # Docker Compose runtime variables, ignored by Git
```

## Automatic Configuration

Supported environment variables:

- `REPO_URL`: proxy deployment repository to clone or update. Defaults to this repository.
- `PROXY_DOMAIN`: required for generated config. NaiveProxy HTTPS domain.
- `ACME_EMAIL`: required for generated config. Caddy ACME email.
- `SITE_DOMAIN`: optional website/V2Ray domain. Defaults to `PROXY_DOMAIN`.
- `NAIVE_USER`: optional NaiveProxy username. Defaults to `proxy`.
- `NAIVE_PASSWORD`: optional NaiveProxy password. Generated when empty.
- `VMESS_UUID`: optional V2Ray VMess UUID. Generated when empty.
- `WS_PATH`: optional V2Ray WebSocket path. Defaults to `/test`.
- `AUTO_CONFIG`: `auto`, `1`, or `0`. Defaults to `auto`.
- `CLIENT_ENV_FILE`: generated client values file. Defaults to `.deploy-client.env`.
- `WEB_LOCAL_DIR`: optional existing local directory mounted read-only as `/var/www`. Recommended for larger sites.
- `WEB_DIR`: default website directory relative to `INSTALL_DIR`. Defaults to `www`.
- `SKIP_FIREWALL_CONFIG`: set to `1` to skip automatic UFW configuration.

If `WEB_LOCAL_DIR` is not set, the script creates `www/index.html` with a basic `hello` page and mounts that as `/var/www`.

`AUTO_CONFIG=auto` writes generated config only when the checked-out files still contain placeholders. Use `AUTO_CONFIG=1` to force regeneration on every deployment. Use `AUTO_CONFIG=0` if you maintain `Caddyfile` and `config.json` yourself.

Ports `80` and `443` must be open, and all configured domains must resolve to the server before Caddy can issue TLS certificates. If `ufw` is installed and active, the deploy script automatically runs `ufw allow 80/tcp` and `ufw allow 443/tcp`.

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

Update the proxy repo while keeping a local website directory:

```bash
cd /opt/proxy-server-deploy
sudo WEB_LOCAL_DIR=/srv/www ./deploy.sh
```
