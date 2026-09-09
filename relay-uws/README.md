# Hollow Relay

High-performance WebSocket relay and signaling server for **Hollow**, a fully distributed, encrypted communication platform.

Built with [uWebSockets](https://github.com/uNetworking/uWebSockets) (C++) for maximum connection density. A single $8/month VPS handles **~572,000 concurrent connections** at 13.4 KB per connection with native TLS.

## Documentation

- **[BENCHMARK.md](BENCHMARK.md)**: stress test results, 44,600 simultaneous connections with per-connection memory analysis and capacity projections.
- **[WHITEPAPER.md](../WHITEPAPER.md)**: the full Hollow protocol specification, cryptographic architecture, networking model, threat model, and security properties.

## What the relay does

The relay is a lightweight message router. It keeps nothing on disk, cannot decrypt content, and holds no user data beyond ciphertext waiting for an offline peer (see [Restart persistence](#restart-persistence)). All it does is:

- **WebSocket rooms**: peers join named rooms and exchange end-to-end encrypted messages through the relay. The relay forwards opaque blobs; it cannot read them.
- **Binary protocol**: `0x01` for room broadcasts, `0x02` for targeted peer-to-peer delivery, `0x03`/`0x04` for bandwidth-optimized message broadcast/direct (25-42% savings vs JSON), `0x07`/`0x08` for topic-routed channel messages (per-channel pub/sub). The relay rewrites target fields to sender fields on forwarding.
- **Offline delivery buffers**: ciphertext for peers who are away, in RAM only, deleted on delivery or expiry.
- **TURN credential generation**: time-limited HMAC-SHA1 credentials for NAT traversal via coturn (`/turn-credentials`).
- **License key gating**: optional closed-beta access control via a `keys.json` file, with 30-second hot-reload and active connection revocation.
- **Server stats**: live memory, bandwidth, and online user count via `/server-stats` (reads `/proc` on Linux).

## Performance

Measured on an OVH VPS (4 vCPU / 8 GB RAM; 400 Mbps at measurement time, 1 Gbps since 2026-08-04; the connection figures are RAM-bound and unaffected). Verified with 44,600 simultaneous authenticated WebSocket connections. See [BENCHMARK.md](BENCHMARK.md) for full methodology and data.

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
- **Native TLS** via OpenSSL (TLS 1.3, AES-256-GCM), no reverse proxy needed.
- **Backpressure handling**: 64 MB hard ceiling (`.maxBackpressure`). No soft cap or message dropping, which was removed because it silently broke CRDT sync. Dead connections are caught by the hard limit. Clients auto-resync via CRDT/gossip if messages are lost.
- **Payload limits**: 64 MB max payload (`maxPayloadLength`). Text frame 1 MB size cap. Per-peer room cap (10,000 rooms). No binary rate limiting; authenticated peers are trusted, and Ed25519 auth plus license key revocation is the DoS defense model.
- **Room membership enforcement**: peers cannot send to rooms they haven't joined.
- **Inbox mailbox ownership proof**: a friend request for an offline stranger is buffered under their MASTER id, which no socket ever authenticates as. A device reads that mailbox only by carrying its master-signed device list as `inbox_proof` on the `inbox:{master}` join. Four things must all hold: the signature verifies, the public key derives to the claimed master id, the joining device is still listed and not revoked, and the room is that master's own inbox. A failed proof replays nothing and answers nothing. A read never consumes the mailbox, so every sibling device collects the request once, and the relay records nothing about who deposited or read what.
- TURN credentials are time-limited (1 hour TTL) and derived from an environment variable (`TURN_SECRET`), never hardcoded.

## Restart persistence

Everything the relay holds is RAM: the offline DM buffers, the per-channel topic rings, the opt-in retention registrations, push tokens and push preferences. Until 2026-09-07 all of it ended with the process, so every deploy emptied up to three days of undelivered messages and dropped every offline phone's push token.

Now, on SIGTERM, the relay serialises that state into an anonymous memory file (`memfd_create`) and hands the descriptor to systemd's file descriptor store. systemd holds it across the restart and passes it back to the next process, which restores the buffers, drops the descriptor from the store, expires whatever aged out in the gap, and only then listens. Memory to memory, never a file: a full `systemctl stop` clears the store, and a reboot or power loss loses everything, which is the privacy promise.

The unit needs two lines or systemd silently drops the handoff (`deploy/hollow-relay.service` has them):

```ini
NotifyAccess=main
FileDescriptorStoreMax=1
```

Two more things on the host keep "never on disk" literally true, because the relay's heap and the handed-over memory are both ordinary pageable memory:

- **No swap.** A swapfile lets the kernel page relay memory, ciphertext and peer ids included, onto the SSD. The production box runs with none.
- **No core dumps.** `LimitCORE=0` on the unit (and apport disabled on the host), or a crash writes the whole heap to disk.

Under Docker there is no fd store, so the handoff no-ops and buffers end with the container. The codec has its own unit test:

```bash
cd test && g++ -std=c++17 -I../src test_snapshot_codec.cpp -o test_snapshot_codec && ./test_snapshot_codec
```

A side effect worth knowing: the relay now exits cleanly. It used to close only its listen socket on SIGTERM, and the periodic timers plus every open connection kept the event loop alive until systemd's 90-second stop timeout killed it, so a restart was a 90-second brownout for new connections. It is now well under a second.

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

### Requirements

1. Create a user to run the Docker container (we assume "hollow" in the examples).
2. Add the user to the Docker group.
3. If you have SELinux installed be sure persistent storage is properly
   labeled. This ensures the services running on the container can write
   to their mounted storage.
4. Install Docker Engine with the Docker Compose Plugin.
5. Clone this repo in /opt and make hollow the owner of all the files.

Note: `docker compose up` will build the hollow-relay binary as part of the startup process. There is no need to install the dependencies or run through the build process above.

```bash
cp .env.example .env              # edit with your domain, IP, TURN secret
cp turnserver.conf.example turnserver.conf  # edit realm + secret + allowed-peer-ip (your public IPs)
git submodule update --init --recursive
docker compose up -d
```

This starts the relay (TLS on 443), certbot (auto Let's Encrypt), and coturn (TURN on 3478). See `.env.example` for configuration.

After the relay is up and running you can use the provided systemd unit file as a template to ensure the service starts up after reboots. See `deploy/hollow-relay-docker-compose.service` Additionally install `deploy/hollow-relay-cert-renewed.path` and `deploy/hollow-relay-cert-renewed.service` if you want to handle cert renewals gracefully. 

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
| `--forwarder-peer-id` | *(none)* | Media forwarder peer_id advertised via `get_media_forwarder` (startup-load; restart on rotation) |

### License keys format (`keys.json`)

```json
{
  "enabled": true,
  "keys": ["key1", "key2", "key3"]
}
```

Where keyN is four groups of four characters [A-Z0-9] separated by hyphens. (eg. AB12-CD32-BA30-LJ50)

The file is hot-reloaded every 30 seconds. Removing a key revokes the active connection using it.

## Deployment

The relay terminates TLS natively, so no Nginx or reverse proxy is needed:

```
Client (WSS :443) --> hollow-relay (TLS via OpenSSL)
```

Grant the binary permission to bind port 443 without root:

```bash
sudo setcap cap_net_bind_service=+ep ./build/hollow-relay
```

A sample systemd service file is provided in `deploy/hollow-relay.service`. Keep its `NotifyAccess`, `FileDescriptorStoreMax` and `LimitCORE` lines (see [Restart persistence](#restart-persistence)).

For certificate renewal, use certbot with a deploy hook:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/reload-relay.sh
#!/bin/bash
systemctl restart hollow-relay
```

## Architecture

```
src/
  main.cpp           Entry point, CLI parsing, timer setup, shutdown
  config.h           Config struct
  state.h            All shared state (single-threaded, no locks)
  crypto.h/.cpp      Ed25519 (libsodium), HMAC-SHA1 (OpenSSL), base64
  license.h/.cpp     License key load/validate/hot-reload/revocation
  http_handlers.h/.cpp  HTTP endpoints
  ws_handler.h/.cpp  WebSocket auth, room routing, binary protocol
  offline_index.h    Fair-share eviction index over the offline buffers
  snapshot_codec.h   Wire form of the restart snapshot (unit tested)
  snapshot.h/.cpp    Snapshot capture/restore against RelayState
  sd_fdstore.h       systemd fd store handoff (hand-rolled sd_notify)
  validate.h         Peer-id and room-code shape checks
  json.hpp           nlohmann/json (vendored single-header)
```

The relay is single-threaded by design. uWebSockets' epoll event loop handles all connections on one thread with correct backpressure and write draining. No mutexes, no atomics, no race conditions. For multi-core scaling, run multiple instances behind `SO_REUSEPORT`.

## License

MIT, see [LICENSE](LICENSE).
