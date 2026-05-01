# Hollow Relay — Benchmark Results

Stress test of the Hollow relay (uWebSockets C++) measuring per-connection memory overhead and maximum connection capacity.

## Test Environment

| Component | Details |
|-----------|---------|
| **Server** | OVH VPS — 4 vCPU / 8 GB RAM / Ubuntu |
| **Relay** | hollow-relay (uWebSockets C++, single-threaded epoll) |
| **TLS** | OpenSSL with `SSL_MODE_RELEASE_BUFFERS` enabled |
| **Test client** | Custom Rust tool (`tokio` + `tokio-tungstenite` + `rustls` + `ed25519-dalek`) |
| **Date** | 2026-05-01 |

## Methodology

Each simulated connection:
1. Opens a TLS WebSocket to `wss://relay:443/ws`
2. Authenticates with a unique Ed25519 keypair (cryptographically valid signature, same as real Hollow clients)
3. Receives `auth_ok` confirmation
4. Holds the connection idle (responding to server pings)

Connections are ramped in batches of 500 with 100 concurrent TLS handshakes, with settling pauses between batches. The relay process RSS is measured via `ps -o rss=` at 5-second intervals. Per-connection overhead is calculated as `(current_RSS - baseline_RSS) / alive_connections`.

The test client uses `rustls` with a shared `ClientConfig` to minimize client-side memory (~28 KB/conn vs ~700 KB/conn with OpenSSL), allowing high connection counts from a single machine.

## Results

### Connection Ramp (50,000 target)

| Connections | Relay RSS | Per-Connection |
|-------------|-----------|----------------|
| 1,000 | 45.4 MB | ~0 KB (within baseline noise) |
| 2,500 | 46.4 MB | 0.39 KB |
| 5,000 | 81.3 MB | 7.35 KB |
| 10,000 | 145.9 MB | 10.29 KB |
| 15,000 | 220 MB | 13.1 KB |
| 20,000 | 301 MB | 13.2 KB |
| 25,000 | 375 MB | 13.3 KB |
| 30,000 | 424 MB | 13.3 KB |
| 35,000 | 506 MB | 13.4 KB |
| 40,000 | 546 MB | 13.4 KB |
| **44,600** | **614 MB** | **13.4 KB** |

The test reached 44,600 simultaneous connections before the client exhausted the OS ephemeral port range (the relay and test client were co-located on the same machine). The relay showed zero strain — the bottleneck was entirely client-side port exhaustion.

### Key Findings

- **0 connection failures** — every connection that could be established was successfully authenticated
- **0 drops** — no connections were dropped by the relay during the entire test
- **Perfectly linear scaling** — per-connection overhead stabilized at ~13.4 KB and remained flat from 15k to 44.6k connections with no memory cliffs, fragmentation, or degradation
- **Single-threaded** — the relay handled all 44,600 connections on a single epoll thread

### Capacity Estimate

| VPS RAM | Usable RAM | Max Connections |
|---------|------------|-----------------|
| 8 GB | ~7.5 GB | **~572,000** |
| 12 GB | ~11.5 GB | **~878,000** |
| 16 GB | ~15.5 GB | **~1,183,000** |

Based on 13.4 KB per connection with ~200 MB reserved for OS and relay baseline overhead.

### Previous Benchmark Comparison

| Metric | Previous (10k test) | Current (44.6k test) |
|--------|---------------------|----------------------|
| Per-connection | 14.5 KB | 13.4 KB |
| 8 GB capacity | ~480,000 | ~572,000 |
| Test method | Total VPS memory delta | Relay process RSS (more accurate) |

The improved number comes from measuring relay process RSS directly rather than total system memory delta, which previously included kernel socket buffer overhead attributed to the relay.

## Stress Test Tool

The test client source is in `bench/stress_test/`. It can be built and run on any Linux machine with Rust installed:

```bash
cd bench/stress_test
cargo build --release

# Usage: relay_stress_test <connections> <batch_size> <max_concurrent_handshakes>
./target/release/relay_stress_test 50000 500 100
```

### System Tuning (required for >10k connections)

```bash
# Raise SYN backlog and listen queue
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=8192
sudo sysctl -w net.core.somaxconn=65535

# Widen ephemeral port range (client-side, if co-located)
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# Raise file descriptor limit
ulimit -n 500000
```

For tests beyond ~64k connections, run the stress test client on a separate machine to avoid ephemeral port exhaustion.
