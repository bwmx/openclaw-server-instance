# OpenClaw + AC2 pairing server

Publicly accessible OpenClaw instance on Ubuntu with the Algorand Foundation **AC2** reference plugin. A user opens a token-protected web page, presses "Start pairing session", and scans the QR code (produced by `openclaw ac2 pair`) with their AC2 Controller / wallet. The pairing session stays alive for 15 minutes (configurable), then auto-expires.

## Architecture

```
                          public internet
                                │
                    Cloudflare (proxied, SSL/TLS: Full)
                                │
                          :443 / :80
                                │
┌── docker ──────────────────────────────────────────────┐
│  caddy                                                   │
│  self-signed cert (`tls internal`) ─┐                    │
│                                     ▼                    │
│  openclaw-gateway            pair-manager               │
│  node dist/index.js gateway  (same network namespace)   │
│  :18789 (loopback-published) ├─ HTTP :8377 QR page      │
│                              └─ spawns `openclaw ac2    │
│         shared volume:          pair`, parses           │
│         /home/node/.openclaw    "Pairing URL: …",       │
│                                 kills it after TTL      │
└─────────────────────────────────────────────────────────┘
        │ outbound only
        ▼
  Liquid Auth signaling server (WebRTC/TURN)  ←— wallet scans QR
```

Notes on why it's built this way:

- **AC2 traffic is outbound.** Pairing and chat run over Liquid Auth signaling + WebRTC (TURN over TCP/TLS thanks to the libnice build), so the only inbound public ports needed are for the QR page itself.
- **Cloudflare sits in front, proxied.** The A record is orange-clouded, so only Cloudflare's proxied port list works — the pair page is fronted by Caddy on 80/443 instead of being exposed directly on a nonstandard port. Caddy terminates TLS with a self-signed cert (`tls internal`); Cloudflare's SSL/TLS mode must be set to **Full** (not Flexible — that would send the pairing token to the origin in cleartext; not Full strict — that requires a CA-signed origin cert, which this setup deliberately avoids in favor of a self-signed one).
- **The pairing session lives in the `ac2 pair` process.** The pair-manager keeps that child process alive for the TTL and terminates it afterwards; `ac2 forget` resets to a fresh state.
- **The plugin is baked into the image** at build time (install + native rebuilds per the plugin README: `@napi-rs/keyring` via prebuild, `node-datachannel` compiled from source with `USE_NICE=1` against libnice). The named volume `openclaw_data` is seeded from the image on first run, so plugin files and wiring persist.
- **Hardening:** the gateway/pair-manager containers run as non-root `node`; all three containers use `cap_drop: ALL` (caddy adds back only `NET_BIND_SERVICE`, needed to bind 80/443), `no-new-privileges`, and pids/memory/CPU limits, with tmpfs `/tmp` on the node containers. The gateway port 18789 is published on host loopback only, and the pair page is not published to the host at all — only reachable through caddy. The pairing page requires a secret token and auto-expires sessions.

## Prerequisites

- Ubuntu server (22.04+/26.x LTS) with a public IPv4
- Docker Engine + Compose v2 (`curl -fsSL https://get.docker.com | sh`)
- ≥ 2 GB RAM (image build compiles native code)
- An API key for your model provider (asked during onboarding)
- A domain with a Cloudflare-proxied A record pointed at the server's IP

## Cloudflare setup

1. DNS record for your domain: type `A`, value = server's public IP, proxy status **Proxied** (orange cloud).
2. SSL/TLS → Overview → encryption mode: **Full** (not Flexible, not Full strict — Caddy serves a self-signed cert, which Full accepts without CA validation).
3. Set `DOMAIN=` in `.env` to that hostname before running setup.

## Deploy

```bash
# on the server
git clone <this repo> openclaw-server && cd openclaw-server   # or scp the folder
chmod +x scripts/setup.sh pair-manager/entry.sh
./scripts/setup.sh
```

The script generates `.env` (gateway token + pairing-page token), builds the image, runs interactive OpenClaw onboarding (pick provider, paste API key), verifies the AC2 wiring (`plugins enable` + `ac2 setup`), and starts the stack. It prints the pairing URL at the end:

```
https://<DOMAIN>/?token=<PAIR_TOKEN>
```

Open the firewall for the pairing page (fronted by Caddy — the pair-manager port itself is never published to the host):

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

## Using the pairing page

Open the URL, press **Start pairing session**. Within a few seconds the QR appears (the page polls and re-renders automatically — the plugin re-issues a fresh QR if a pairing attempt times out). Scan it with the AC2 Controller/wallet. The countdown shows time until auto-expiry (default 15 min, `PAIR_SESSION_TTL_MS` in `.env`).

Buttons: **Start pairing session** launches/relaunches `openclaw ac2 pair`; **Forget pairing** kills the session and runs `openclaw ac2 forget` (clears session, connection state, and stored agent identities) for a fresh instance.

API (same token): `GET /api/session`, `POST /api/pair`, `POST /api/forget`, `GET /healthz` (no token).

## Day-2 operations

```bash
docker compose logs -f pair-manager        # pairing activity
docker compose logs -f openclaw-gateway    # gateway/agent logs
docker compose restart                     # restart stack
docker compose down && docker compose up -d --build   # rebuild after changes

# Control UI (loopback only) — from your laptop:
ssh -L 18789:127.0.0.1:18789 user@server   # then open http://127.0.0.1:18789

# One-off CLI commands inside the running netns:
docker compose exec openclaw-gateway node dist/index.js ac2 status
```

To change the Liquid Auth signaling server, set `AC2_LIQUID_AUTH_SERVER` in `.env` and `docker compose up -d`.

## Troubleshooting

**Build OOM (exit 137):** the node-datachannel source build needs ~2 GB RAM. Add swap or use a bigger instance.

**QR never appears:** check `docker compose logs pair-manager` and the page's Debug log. Common causes: onboarding not completed (no model provider configured), or the Liquid Auth server unreachable (egress blocked — the container needs outbound 443).

**Keystore warnings / identity not persisted:** the plugin stores the agent's wallet-issued key via the OS keychain (`@napi-rs/keyring`). The pair-manager entrypoint starts DBus + gnome-keyring inside the container; if that fails the plugin degrades gracefully — pairing still works, but the wallet re-issues the agent identity on each new pairing instead of reusing it.

**Wallet can't connect after scanning (NAT/firewall):** WebRTC needs outbound UDP or TURN. The image compiles node-datachannel against libnice specifically so TURN over TCP/TLS works from restrictive networks; ensure outbound 443/TCP is open.

**Permission errors on the volume (EACCES, uid 1000):** the containers run as uid 1000. If you switch to bind mounts, `chown -R 1000:1000` them.

**Fresh start:** `docker compose down -v` deletes the named volume (config, auth, plugin state); rerun `./scripts/setup.sh`.

## Files

| Path | Purpose |
| --- | --- |
| `Dockerfile` | Official OpenClaw image + toolchain + AC2 plugin baked in (native rebuilds included) |
| `docker-compose.yml` | Hardened three-service stack (gateway, pair-manager, caddy), single public surface (80/443) |
| `Caddyfile` | TLS-terminating reverse proxy config (self-signed cert via `tls internal`) fronting the pair page |
| `pair-manager/server.js` | Dependency-free Node HTTP service managing `ac2 pair`/`forget`, TTL, token auth |
| `pair-manager/index.html` | QR page (client-side QR render, live polling, countdown) |
| `pair-manager/entry.sh` | Starts DBus + gnome-keyring, then the pair-manager |
| `scripts/setup.sh` | One-shot server setup (env, build, onboarding, start) |
| `.env.example` | Configuration template |
