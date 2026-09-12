# Anti-Censorship Transport — Design & Decision Report (2026-07)

**Status:** Research complete, design locked, implementation not started.
**Author:** Deep-research workflow (105 agents, 24 sources, 25 adversarially-verified claims) + follow-up confirmation searches.
**Scope:** How Hollow reaches its relay from inside Russia (TSPU), China (GFW), Iran, and the UK (OSA) in 2026.
**Supersedes:** The stale "Phase ???: Fight Government Censorship" narrative in `HOLLOW_PLAN.md` (which still framed Shadowsocks / DIY-rustls-camouflage as the path — both now known to be the wrong bet).

---

## 0. TL;DR (the decision)

- **The problem is not IP blocking. It is inner-traffic fingerprinting.** TSPU/GFW look at the *shape* of the traffic inside the tunnel — TLS-1.3-over-TCP to a foreign-datacenter IP, real-time flow, server-heavy volume — and block on that, regardless of the outer wrapper or the port. Hollow's plain WSS-on-443 is therefore fingerprintable **as-is**. This is exactly why our Russian tester's packets were dropped while a VPN worked.
- **Primary transport to embed: VLESS + REALITY (XTLS-Vision).** It is the community-rated most-survivable transport in 2026 — "disrupted-not-killed." When Russia blocked *plain* VLESS in late 2025, REALITY kept working and providers simply re-issued REALITY configs.
- **Client side (Hollow app, Rust):** the **`cfal/shoes`** crate — MIT-licensed, single Rust codebase, has `lib.rs` + an `ffi/` module, ships `reality/`, `shadow_tls/`, `vless/`, `shadowsocks/`, `websocket/`, `hysteria2`, `tuic` implementations, and `android/` + iOS TUN support. It is embeddable, not just a binary.
- **Server side (VPS, any language):** run **Xray-core** (Go) — the reference REALITY implementation, actively developed (v26.x, "Reality-Vision" framework shipped Feb 2026). Running Go alongside the existing uWebSockets C++ relay and the hollow-push service is a non-issue — it's just another listener on the box.
- **Key correction (read this):** REALITY does **NOT** use our own Let's Encrypt certificate. It borrows a *real external website's* certificate at handshake time. Our uWebSockets Let's Encrypt cert is irrelevant to REALITY — but it stays relevant to the ShadowTLS / plain-WSS fallback. See §5.
- **Explicitly dead — do not build:** plain Shadowsocks/SS-2022, VMess, AmneziaWG, OpenVPN, and any "just change the port" scheme.

---

## 1. Why the old plan was wrong

The previous plan (and our own earlier attempt) assumed:

1. **Shadowsocks-2022 would work** — it doesn't. TSPU detects even heavily-obfuscated Shadowsocks within hours, ~95% detection since Sept 2024. We already implemented it, tested it from Russia, watched it die in ~20s, and removed it. That removal was **correct** and must not be revisited.
2. **A DIY rustls TLS-camouflage wrapper was the next step** — this reinvents REALITY badly. Hand-rolling browser-like ClientHello fingerprints is exactly the wheavy, fragile, always-behind work that REALITY (with bundled uTLS) already does correctly and keeps current against AI-driven TLS fingerprinting. Building our own is strictly worse.
3. **Changing ports / cover protocols helps** — refuted (0-3 in verification). "Move to a random high port → 80% delivery restored" did **not** survive scrutiny. Detection is not port-heuristic.

The real 2026 picture: this is an active cat-and-mouse where **REALITY is the only widely-deployed thing still standing**, and the entire game is making the *inner* handshake look like a genuine connection to a real, popular, unblockable website.

---

## 2. The threat model that actually applies (2026)

Confirmed 3-0 across net4people/bbs #363 (ntc.party), zona.media (2026-04), and HRW (2025-07):

- **TSPU is centrally controlled and covers 100% of Russian uplinks** (mobile, broadband, transborder) — coverage completion targeted for 2026.
- **Detection heuristic (evolved):** TLS-1.3 over TCP to a foreign-datacenter IP where the server→client volume exceeds ~15-20 KB and the flow looks like an HTTPS tunnel carrying HTTPS. The earlier "≥3 packets each ≥411 bytes" signature is superseded/partial (that specific claim was refuted 1-2).
- **It can throttle by any percentage or block outright** — a messenger's distinctive traffic signature makes it identifiable regardless of encryption.
- **Emerging vectors:** foreign-datacenter-IP correlation and **IP/CIDR whitelisting**. This is the strategic risk for Hollow: a single known VPS IP may become the weak link *regardless* of obfuscation quality. (See §7.)

China's GFW adds **active probing** and did an **unconditional port-443 RST block in Aug 2025** (gfw.report) — so WSS-on-443 alone is not sufficient there; REALITY's active-probe defense (fallback to the real target site) is what matters.

---

## 3. Field status of every candidate (what's alive, what's dead)

| Transport | 2026 status | Verdict for Hollow |
|---|---|---|
| **VLESS + REALITY (XTLS-Vision)** | Disrupted-not-killed. Plain VLESS blocked in RU late 2025; REALITY survived, providers re-issued configs. ~98-99% bypass through early 2026. | **PRIMARY.** Best available. |
| **ShadowTLS v3** | Rust-native protocol; strong in-process TLS camouflage. Upstream binary is Linux-only (Monoio/io_uring). | **FALLBACK / alt layer** — via `shoes`' own portable implementation, not the upstream binary. |
| Plain Shadowsocks / SS-2022 AEAD | ~95% detection since Sept 2024, killed in hours/~20s. | **DEAD. Avoid.** |
| VMess | Fingerprinted, blocked. | **DEAD. Avoid.** |
| AmneziaWG | Blocked in RU 2025 (Amnezia's own tracker admits DPI detection). | **DEAD. Avoid.** |
| OpenVPN / WireGuard / IKEv2 | Among the 7+ protocols HRW documents as blocked in RU. | **DEAD. Avoid.** |
| Hysteria2 / TUIC (QUIC/UDP) | Russia periodically throttles UDP; unreliable. Available in `shoes` if wanted. | **Optional 3rd option**, not primary. |
| Domain-fronting / meek | Largely dead (major CDNs disabled it years ago). | Not pursued. |
| Tor WebTunnel | Validates our WSS-on-443 shape; Tor investing in it for 2026. Not embeddable into Hollow; GFW RST-blocked 443 in Aug 2025. | **Reference design to emulate, not a library.** |

---

## 4. Client implementation path — `cfal/shoes` (Rust, embeddable)

**Confirmed facts (primary source: the repo itself):**

- **License:** MIT — compatible with Hollow's AGPL-3.0/MIT open-source plan.
- **Crate shape:** `src/lib.rs` **and** `src/main.rs` (hybrid), plus a dedicated **`src/ffi/`** module and a `cbindgen.toml` + `include/` directory → a C-ABI surface exists. So it can be linked as a Rust dependency *or* driven over FFI, not only spawned as a binary.
- **Relevant modules present:** `reality/`, `reality_client_handler.rs`, `shadow_tls/`, `vless/`, `shadowsocks/`, `websocket/`, `tls_client_handler.rs`, `rustls_config_util.rs`, `hysteria2_server.rs`, `tuic_server.rs`, `tun/`.
- **Protocols:** VLESS, Shadowsocks (incl. SS-2022 blake3 AEAD), Trojan, Snell v3, Hysteria2, TUIC v5, AnyTLS, NaiveProxy, VMess AEAD.
- **Transports:** TCP, QUIC, WebSocket (SIP003), **ShadowTLS v3**, TLS, **XTLS Reality**, **XTLS Vision**.
- **Mobile:** ships an `android/` directory; iOS listed under supported platforms.
- **Config:** YAML, hot-reloadable, works as both client and server.

**How it plugs into Hollow (the shape):**

```
[Proxy OFF — normal users]
Hollow Rust node ── WSS/443 ──▶ relay.anonlisten.com (uWebSockets)

[Proxy ON — censored users]
Hollow Rust node ──▶ shoes client (in-process, REALITY/XTLS-Vision) ──▶ VPS:443 (Xray REALITY server)
                                                                          └─▶ localhost ──▶ uWebSockets relay
```

The Hollow node dials a local loopback endpoint that `shoes` exposes; `shoes` performs the REALITY handshake outbound to the VPS; the VPS Xray server authenticates the REALITY client and forwards the decrypted stream to the local uWebSockets relay. **Everything the Hollow node speaks is unchanged** — it still opens a WSS connection; it just opens it *through* the local shoes tunnel when proxy mode is on.

**The iOS win, spelled out:** the reason stock Xray/sing-box dies on iOS is its **monolithic geo-routing files** exhausting the ~50 MiB Network-Extension memory budget (15 MiB for App-Proxy). **Hollow needs zero geo-routing — it dials ONE relay.** A single-destination Rust transport with no geo-data sidesteps the exact thing that breaks everyone else on iOS. This is a genuine architectural advantage, not a hope.

**Two required pre-build spikes (do these before committing):**

1. **Embeddability spike:** clone `shoes`, confirm the `lib.rs` / `ffi/` public surface is usable for an in-process *client* (not just server), and confirm it cross-compiles for `aarch64-apple-ios` + Android within the NE memory budget. If the crate API is server-centric, fall back to: (a) driving it over its C-ABI, or (b) spawning it as a subprocess on desktop while doing a Network-Extension embed on mobile.
2. **Client/server interop spike:** stand up Xray REALITY server on a throwaway VPS, point `shoes` REALITY client at it, confirm a clean WSS tunnel end-to-end before touching the real relay.

---

## 5. Server implementation path — Xray-core (Go, on the VPS)

**Xray-core is the reference REALITY server** and the right choice for the VPS side:

- Reference implementation of REALITY + XTLS-Vision; actively developed (v26.x through 2026; the "Reality-Vision" framework shipped Feb 2026 specifically to defeat AI-driven TLS fingerprinting).
- Go, single binary, config-driven. **Running it alongside uWebSockets (C++) and hollow-push is fine** — it's an independent listener on 443 that forwards to the relay over loopback. No interference.
- `sing-box` is a viable alternative (unified config, also Go) but Xray "went deep on stealth/anti-detection" while sing-box "went for performance/unification" — **for a stealth-first single-relay use case, Xray is the better fit.** sing-box is the pick only if we later want to multiplex many protocols from one config.

### 5.1 The certificate correction (important — this changes your assumption)

**REALITY does NOT use our own domain's Let's Encrypt certificate.** This is the single most-misunderstood part and it directly affects the "reuse our uWebSockets cert" idea:

- REALITY issues a **temporary trusted certificate** (signed by a temporary auth key) to *authenticated Hollow clients*. Our real cert never appears to them.
- To *everyone else* (censors, probers, MITM), the REALITY server **borrows a real external website's certificate** by forwarding the ClientHello to a chosen **`target`/`dest`** site (e.g. a big CDN-backed domain running TLS 1.3 + H2) that **we do not need to own**. The censor probing our IP sees a genuine handshake for that legitimate site.
- Server config is therefore: a list of acceptable `serverNames` (SNI), an external `target` website, an X25519 `privateKey`, and `shortIds`. **No Let's Encrypt cert is involved in the REALITY path at all.**

**So where does our Let's Encrypt cert still matter?** Two places:
1. The existing **plain WSS relay** on 443 (uWebSockets) — unchanged, still uses our cert for normal (uncensored) users.
2. If we add a **ShadowTLS / plain-TLS fallback** transport (not REALITY), *that* layer can present our real Let's Encrypt cert. REALITY = borrowed foreign cert; ShadowTLS/WSS = our own cert. Keep the two mental models separate.

### 5.2 Port 443 coexistence

REALITY supports **fallback**: unauthenticated/failed handshakes are forwarded to the `target` site (or a local web server), so a single 443 can serve REALITY users *and* look like a real website to probers. Whether REALITY and the uWebSockets relay share 443 or sit on separate IPs/ports is an ops decision for the spike — REALITY's fallback makes co-location on 443 possible, but the cleanest first cut is REALITY on 443 forwarding authenticated streams to the relay on loopback.

---

## 6. Ranked recommendation

1. **PRIMARY — VLESS + REALITY (XTLS-Vision):** `shoes` client (Rust, embedded) ↔ Xray-core server (Go, VPS). Best survivability, correct against both TSPU and GFW active probing, and our single-relay/no-geo design dodges the iOS memory trap.
2. **FALLBACK — ShadowTLS v3** (via `shoes`' portable Rust implementation) wrapping the existing WSS, presenting our own Let's Encrypt cert. Simpler, uses our cert, good second option if a REALITY config gets burned.
3. **OPTIONAL 3rd — Hysteria2/TUIC** (QUIC) for networks where UDP isn't throttled — already in `shoes`, low marginal cost to expose.
4. **AVOID (known-dead):** plain Shadowsocks/SS-2022, VMess, AmneziaWG, OpenVPN/WireGuard, port-hopping-only schemes, DIY rustls ClientHello camouflage.

---

## 7. Open risks & things to re-validate before ship

- **Time-sensitivity is severe.** Every status claim is a snapshot in an active arms race; the REALITY > everything-else ranking holds as of early 2026 but **must be re-checked immediately before implementation** (ntc.party, net4people/bbs, XTLS issues).
- **Single-IP risk.** TSPU's move toward foreign-datacenter-IP correlation + IP/CIDR whitelisting means a single known relay IP could be blocked *regardless* of transport. Longer-term mitigations to keep on the radar: CDN-fronting the REALITY endpoint, or **rotating relay IPs** / multiple relay IPs distributed to clients. Out of scope for v1 but a real strategic ceiling.
- **China/Iran/UK evidence is thin.** The verified evidence base is overwhelmingly Russia/TSPU. REALITY is validated-for-Russia and *probable* for China (its active-probe defense is China-focused by design) but the GFW cat-and-mouse shifts monthly. Treat non-Russia claims as lower confidence.
- **UI/UX plumbing already exists.** The dead `proxyEnabledProvider` (Dart) and the local-tunnel → VPS → relay architecture from the removed Shadowsocks attempt can be **reused** — only the tunnel protocol changes (Shadowsocks → REALITY). Auto-detect-and-fallback (WSS fails → flip proxy on) is the right long-term UX; a manual toggle is the fast path.

---

## 8. Concrete next steps

1. **Spike A (embeddability):** verify `shoes` `lib.rs`/`ffi` client surface + iOS/Android cross-compile within NE memory budget.
2. **Spike B (interop):** Xray REALITY server on a throwaway VPS ↔ `shoes` REALITY client ↔ WSS tunnel end-to-end.
3. **Re-validate field status** (ntc.party / net4people / XTLS issues) at implementation time.
4. Only then: wire proxy-mode into the Hollow node, revive the Dart toggle, and test from Russia with the same tester who confirmed the drop.

---

## Sources (verified)

- net4people/bbs #363 (ntc.party) — TSPU inner-HTTPS fingerprinting mechanism
- zona.media (2026-04-07) — Russian censorship 2026, VLESS block + REALITY survival
- HRW "Disrupted, Throttled and Blocked" (2025-07-30) — 7+ blocked protocols, TSPU coverage
- gfw.report (2025-08-20) — GFW unconditional port-443 RST block
- XTLS/Xray-core #4422 — iOS Network-Extension 50 MiB / 15 MiB memory limit
- XTLS/REALITY README — certificate borrowing, target/SNI, port-443 fallback
- github.com/cfal/shoes (+ `src/`) — Rust crate, lib.rs + ffi/, protocol/transport list, MIT, android/iOS
- github.com/ihciah/shadow-tls — ShadowTLS v3 Rust, Linux-only upstream binary
- github.com/shadowsocks/shadowsocks-rust — embeddable Rust SS crates (fallback base)
- SagerNet/sing-box + getlantern/sing-box-libbox — Go, gomobile/NE binding (why it's the wrong fit)
- blog.torproject.org "Advancing digital rights in 2026" — WebTunnel direction
- Xray-core releases / setup guides (2026) — v26.x, Reality-Vision framework, reference status
