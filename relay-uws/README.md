# Hollow Relay

High-performance WebSocket relay and signaling server for **Hollow** — a fully distributed, encrypted communication platform.

Built with [uWebSockets](https://github.com/uNetworking/uWebSockets) (C++) for maximum connection density. A single $8/month VPS handles **~572,000 concurrent connections** at 13.4 KB per connection with native TLS.

## Documentation

- **[BENCHMARK.md](BENCHMARK.md)** — Stress test results: 44,600 simultaneous connections with per-connection memory analysis and capacity projections.
- **[WHITEPAPER.md](../WHITEPAPER.md)** — Full Hollow protocol specification: cryptographic architecture, networking model, threat model, and security properties.

## What the relay does

The relay is a lightweight, stateless message router. It does **not** store messages, decrypt content, or hold user data. All it does is:

- **WebSocket rooms** — peers join named rooms and exchange end-to-end encrypted messages through the relay. The relay forwards opaque blobs; it cannot read them.
- **Binary protocol** — `0x01` for room broadcasts, `0x02` for targeted peer-to-peer delivery, `0x03`/`0x04` for bandwidth-optimized message broadcast/direct (25-42% savings vs JSON), `0x07`/`0x08` for topic-routed channel messages (per-channel pub/sub). The relay rewrites target fields to sender fields on forwarding.
- **Signaling HTTP** — bootstrap peer discovery (`/register`, `/unregister`, `/bootstrap/{room}`) with Ed25519-signed requests.
- **TURN credential generation** — time-limited HMAC-SHA1 credentials for NAT traversal via coturn (`/turn-credentials`).
- **License key gating** — optional closed-beta access control via a `keys.json` file, with 30-second hot-reload and active connection revocation.
- **Server stats** — live memory, bandwidth, and online user count via `/server-stats` (reads `/proc` on Linux).

## Performance

Measured on an OVH VPS (4 vCPU / 8 GB RAM / 400 Mbps). Verified with 44,600 simultaneous authenticated WebSocket connections — see [BENCHMARK.md](BENCHMARK.md) for full methodology and data.

| Metric | Value |
|---|---|
| Per-connection memory | **13.4 KB** |
| Connections on 8 GB VPS | **~572,000** |
| Connections on 12 GB VPS | **~878,000** |
| Idle relay RSS | **17 MB** |
| Binary size | **636 KB** |
| Threads | **1** (single-threaded epoll) |
| Auth throughput | **800+/sec** |
| Scaling behavior | **Perfectly linear** (verified to 44.6k, 0 failures, 0 drops) |

Key: `SSL_MODE_RELEASE_BUFFERS` frees OpenSSL's 16 KB read/write buffers between messages, keeping per-connection cost low for idle connections. Scaling is verified to be perfectly linear with no memory cliffs or degradation at high connection counts.

## Security properties

- All WebSocket authentication uses **Ed25519 signature verification** with 60-second timestamp skew protection.
- **Native TLS** via OpenSSL (TLS 1.3, AES-256-GCM) — no reverse proxy needed.
- **Backpressure handling** — 64 MB hard ceiling (`.maxBackpressure`). No soft cap or message dropping — removed because it silently broke CRDT sync. Dead connections are caught by the hard limit. Clients auto-resync via CRDT/gossip if messages are lost.
- **Payload limits** — 64 MB max payload (`maxPayloadLength`). Text frame 1 MB size cap. Per-peer room cap (10,000 rooms). No binary rate limiting — authenticated peers are trusted; Ed25519 auth + license key revocation is the DoS defense model.
- **Room membership enforcement** — peers cannot send to rooms they haven't joined.
- TURN credentials are time-limited (1 hour TTL) and derived from an environment variable (`TURN_SECRET`), never hardcoded.

## Building

### Dependencies (Ubuntu/Debian)

```bash
sudo apt install cmake g++ libssl-dev libsodium-dev zlib1g-dev
```

### Build

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

The output is a single binary: `build/hollow-relay` (~636 KB).

## Docker (self-hosting)

```bash
cp .env.example .env              # edit with your domain, IP, TURN secret
cp turnserver.conf.example turnserver.conf  # edit realm + secret
docker compose up -d
```

This starts the relay (TLS on 443), certbot (auto Let's Encrypt), and coturn (TURN on 3478). See `.env.example` for configuration.

## Running (manual)

```bash
# With TLS (production)
./build/hollow-relay \
  --port 443 \
  --public-ip 1.2.3.4 \
  --cert-file /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  --key-file /etc/letsencrypt/live/relay.example.com/privkey.pem

# With license keys + TURN
TURN_SECRET=your_secret ./build/hollow-relay \
  --port 443 \
  --public-ip 1.2.3.4 \
  --keys-file keys.json \
  --cert-file /path/to/fullchain.pem \
  --key-file /path/to/privkey.pem
```

### CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `443` | Listen port |
| `--public-ip` | *(none)* | Public IP of this server |
| `--domain` | `relay.anonlisten.com` | Domain name |
| `--keys-file` | `keys.json` | License keys JSON path |
| `--cert-file` | `/etc/letsencrypt/live/relay.anonlisten.com/fullchain.pem` | TLS certificate chain |
| `--key-file` | `/etc/letsencrypt/live/relay.anonlisten.com/privkey.pem` | TLS private key |

### License keys format (`keys.json`)

```json
{
  "enabled": true,
  "keys": ["key1", "key2", "key3"]
}
```

The file is hot-reloaded every 30 seconds. Removing a key revokes the active connection using it.

## Deployment

The relay terminates TLS natively — no Nginx or reverse proxy needed:

```
Client (WSS :443) --> hollow-relay (TLS via OpenSSL)
```

Grant the binary permission to bind port 443 without root:

```bash
sudo setcap cap_net_bind_service=+ep ./build/hollow-relay
```

A sample systemd service file is provided in `deploy/hollow-relay.service`.

For certificate renewal, use certbot with a deploy hook:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/reload-relay.sh
#!/bin/bash
systemctl restart hollow-relay
```

## Architecture

```
src/
  main.cpp           Entry point, CLI parsing, timer setup
  config.h           Config struct
  state.h            All shared state (single-threaded, no locks)
  crypto.h/.cpp      Ed25519 (libsodium), HMAC-SHA1 (OpenSSL), base64
  license.h/.cpp     License key load/validate/hot-reload/revocation
  http_handlers.h/.cpp  7 HTTP endpoints
  ws_handler.h/.cpp  WebSocket auth, room routing, binary protocol
  json.hpp           nlohmann/json (vendored single-header)
```

The relay is single-threaded by design. uWebSockets' epoll event loop handles all connections on one thread with correct backpressure and write draining. No mutexes, no atomics, no race conditions. For multi-core scaling, run multiple instances behind `SO_REUSEPORT`.

## License

MIT — see [LICENSE](LICENSE).
