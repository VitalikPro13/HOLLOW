# Media Node Swarm: cheap unmetered boxes for TURN and the forwarder

**Status:** PLANNED. Idea agreed 2026-10-21 (Vitalik + Opus session). Nothing built, nothing bought.
**When:** after 0.13 and once real traffic asks for it. Peak relay traffic on 2026-10-21 was about 10 Mbit/s on a 1 Gbit/s port.
**Owner:** Vitalik (architect).
**Builds on:** `MULTI_RELAY_CLIENT_PLAN.md` (the client side of having several relays; this plan is the official domain's own swarm behind one name, which that plan already leaves room for), memory `project_scaling_plan`, `project_relay_fairshare_turn_lock`, `project_media_forwarding_epic`, `reference_relay_scaling`.

---

## 0. TL;DR

Hollow's relay traffic splits into two planes with opposite needs:

| Plane | What | Needs | Lives on |
|---|---|---|---|
| Control | `hollow-relay` (uWebSockets): auth, rooms, presence, text, CRDT and MLS frames, offline rings, push | RAM and CPU, steady, little bandwidth (13.4 KB per socket, ~572k sockets on today's box) | the OVH box, as today |
| Media | coturn (1:1 calls when no direct path exists) and `hollow-forwarder` (screen shares and voice channels) | bandwidth, almost nothing else | a swarm of small unmetered boxes |

Bandwidth is the one thing that gets expensive with one big box (a 2 Gbit/s OVH tier is $14.50/mo, dedicated 10 Gbit/s ports cost hundreds to thousands). Small boxes with their own unmetered 1 Gbit/s port are cheap: Vitalik's IONOS quote is about $6/mo for 1 vCPU, 2 GB RAM and 1 Gbit/s unmetered under fair use, so ten of them is roughly $60/mo for 10 Gbit/s of aggregate media capacity.

The relay stays the brain: it picks the node for each call and each share and hands the client that node's address and short-lived login, exactly the way it hands out TURN logins and the forwarder's id today. No load balancer sits in front of the nodes, and no client ever picks a node by itself.

---

## 1. What exists today (2026-10-21)

- **TURN:** coturn on the relay box. The relay advertises three URIs built from its own `--domain` (`relay-uws/src/turn_uris.h`): `turn:host:3478` (UDP), `turn:host:3478?transport=tcp`, `turns:host:5349` (TLS). Logins are HMAC-SHA1 with a 1 hour TTL, minted from coturn's `static-auth-secret` and sent only on an authenticated socket (`get_turn_credentials`, WHITEPAPER 12.6). The client asks on every connect and every 50 minutes and keeps ONE ICE config for everything (`IceConfigNotifier`).
- **Transport preference:** libwebrtc gathers all three TURN transports at once and ranks UDP above TCP above TLS, so UDP already wins wherever it works and TCP/TLS carry only users on networks that block UDP. Nothing to configure. TLS TURN costs the most CPU per byte, so a weak CPU feels it first.
- **The peer lock:** coturn denies every peer address except the relay host's own (`denied-peer-ip` everything, `allowed-peer-ip` = the relay's v4 and both v6 globals, `no-tcp-relay`). TURN therefore only connects two Hollow allocations (`relay<->relay` pairs) and can never be used as a VPN.
- **CAKE** on the NIC (`bandwidth 950mbit besteffort dual-dsthost`): fair share per destination, only engaged when the line is full. Rule: measure the raw ceiling first, set CAKE about 10 percent under it.
- **Forwarder:** `hollow-forwarder` on the relay box, a Hollow peer with its own identity (`forwarder.key`) and UDP 40000-40199. The relay advertises ONE forwarder peer id (`--forwarder-peer-id`, answered by `get_media_forwarder` with an online bit). Client legs to the forwarder use zero ICE servers, so forwarded media never touches TURN. A share costs `B + B*k` through the forwarder against `2*B*k` through TURN for `k` viewers (`MEDIA_FORWARDING_PLAN.md` 2d).

The heavy traffic at scale is the forwarder (voice channels and screen shares), then TURN (1:1 calls behind hard NATs and "Always relay calls"). Both move to the nodes.

---

## 2. Target shape

```
            clients
   WSS 443 |      \  media (UDP first)
           v       v
   +-------------+   +--------+ +--------+ +--------+
   | OVH relay   |   | node 1 | | node 2 | | node N |   each: coturn + hollow-forwarder
   | hollow-relay|-->| EU     | | EU     | | US     |   own 1 Gbit/s port, own CAKE
   | (control)   |   +--------+ +--------+ +--------+
   +-------------+       ^ forwarder WS (identity + liveness + load)
```

- A **media node** = one small box running coturn and `hollow-forwarder`, nothing else. Same software as today's relay box, so a node is a copy of the existing setup minus `hollow-relay`.
- The relay holds a **node list** (startup config, like `--forwarder-peer-id` today): per node its hostname, region, forwarder peer id and its own TURN secret.
- Node health and load come over the forwarder's own authenticated relay socket (it is already connected for discovery). Liveness = the socket is up. Load = one aggregate number the forwarder reports (bits per second, active legs), never anything per stream, so the relay stays as blind as it is now.

---

## 3. Choosing a node

### 3a. Calls (TURN)
Both people in a call must land on the SAME node. Two nodes would make every packet cross the swarm twice (node 1 out, node 2 in) and cost double.

- **Phase 1 (relay only, no client change):** the relay assigns each client one node when it asks for TURN logins, least loaded in the client's region. Calls between clients on different nodes still work because every node's peer lock allows every other node (section 4), at double the media cost for those calls. Fine while the swarm is small.
- **Phase 2 (sticky per call):** the client asks for logins for a specific call room before the call starts (`get_turn_credentials` gains an optional room code; the relay checks the socket is a member). The relay maps the room to a node with rendezvous hashing over healthy nodes in the region, so both sides get the same node without the relay storing anything per call. The client's ICE config becomes per call instead of global; `IceConfigNotifier` keeps owning it (and keeps owning "Always relay calls": `ref.listen`, never `ref.watch`).

### 3b. Shares and voice channels (forwarder)
A share has one ingest, and every viewer of it must use that same forwarder. `get_media_forwarder` gains the same optional room code and returns the node for that room (same rendezvous hash), so the sharer and every viewer resolve to one forwarder. The existing rebalancer, promotion and presence-tolerance logic stays as is; it just runs against the forwarder the relay named instead of the single configured one. Attribution, consent and "assign trust = originator" rules do not change.

### 3c. Region
The relay already sees each socket's address. Coarse region (EU, NA, later APAC) by address is enough to pick the region; inside a region, load and the hash decide. A call between regions picks the caller's region. IONOS covers Europe and America; Asia would need an OVH box or a local host there.

---

## 4. The peer lock across nodes

Today each coturn only allows the relay host itself. In the swarm:

- Every node's `allowed-peer-ip` lists **every node's** v4 and v6 addresses (its own and its siblings'), so a `relay<->relay` pair across two nodes still connects. `denied-peer-ip` everything else and `no-tcp-relay` stay.
- Never allow a provider's whole prefix (the OVH /64 lesson): neighbours on the same segment would become exits.
- The allow list is generated from the node list, so adding a node means re-rendering every node's coturn config. That is the main reason node rollout needs tooling (section 6), not hand edits.

---

## 5. Secrets and trust

- **One TURN secret per node.** The relay holds all of them (it mints the logins); a node holds only its own. A broken-into $6 box then leaks logins for itself, never the swarm.
- **Forwarder identity per node** (`forwarder.key` each), listed in the relay's node list. A node the relay does not list is never advertised.
- **Node hostnames under the relay's own domain** (for example `m1.relay.anonlisten.com`). The audit noted the client accepts any TURN URI the relay sends (`design_A_inventory/relay.md` E.9); keeping nodes under the relay's domain leaves room for a "same domain as my relay" check later without breaking the swarm.
- **Media stays end-to-end encrypted** on every node (DTLS-SRTP plus SFrame keyed from MLS). A node sees addresses, timing and volume, the same as today's relay box, never content.

---

## 6. Running the boxes

Every node follows the relay box rules (CLAUDE.md, `project_relay_hardening_h`):

- coturn and the forwarder each run as their own account in a systemd sandbox; the repo units ARE the node units.
- Secrets only in root-only `EnvironmentFile`/`LoadCredential`; nothing written to disk (no logs, rsyslog drops `hollow-*`, `ufw logging off`); a denied syscall = EPERM.
- SSH key-only, its own login per node.
- `check-host.sh` grows a node mode (no `hollow-relay`, no fd-store snapshot) and must print only ok after any change.
- CAKE per node, sized from a measured raw ceiling.

Rollout tooling, so a new node is minutes, not an afternoon:

- A node image or template (IONOS offers server images/cloning; to verify) or a single `deploy/node-setup.sh` that turns a fresh Ubuntu into a hardened node from the repo.
- A `node-list` file the relay reads at start, plus a script that re-renders every node's allow list from it (section 4).
- A load balancer in front is NOT needed and does not fit: TURN allocations live on one specific box, and the relay already decides who goes where.

---

## 7. Costs (Vitalik's numbers, 2026-10-21; verify before buying)

| Setup | Media capacity | $/mo |
|---|---|---|
| Today: OVH 4 vCPU / 8 GB / 1 Gbit/s, everything on one box | 1 Gbit/s shared with control | 8.50 |
| OVH next tier, 2 Gbit/s | 2 Gbit/s | 14.50 |
| OVH control box + 3 IONOS nodes | 3 Gbit/s media + the full OVH port for control | ~26.50 |
| OVH control box + 10 IONOS nodes | 10 Gbit/s media | ~68.50 |

Capacity notes:

- TURN carries a stream in and out, so a full-duplex 1 Gbit/s port relays about 1 Gbit/s of calls. The forwarder is limited by its outbound side (`B*k` out per share).
- One 1080p screen share is roughly 2 to 8 Mbit/s, so one node serves dozens to a couple of hundred heavy viewers depending on bitrate.
- Plain UDP relaying at a full 1 Gbit/s is around 100,000 packets a second. One dedicated vCPU should manage that for coturn; TLS TURN and the forwarder do more work per packet. Measure before planning around it (section 9).

---

## 8. Phases

1. **Prepare (no purchase):** node list in relay config; `get_turn_credentials` and `get_media_forwarder` answer with a node from the list (falling back to the local coturn and forwarder when the list is empty, which keeps every self-hosted relay unchanged); forwarder load reporting; peer-lock allow list rendered from the node list; `node-setup.sh` and the node mode of `check-host.sh`. Relay tests cover selection and fallback.
2. **First node:** buy one IONOS box, harden it, measure raw throughput and set CAKE, run a real multi-viewer screen share and a forced-relay call through it (fleet on throwaway identities), watch CPU steal and packet loss.
3. **Sticky selection:** room-keyed node choice for calls and shares (sections 3a, 3b), with the client's per-call ICE config.
4. **Grow:** add nodes per region as traffic asks. The OVH box keeps only control traffic, so its port is free for what it does best.

Self-hosting is unaffected: an empty node list means today's single-box behaviour, and a self-hoster can add nodes the same way if they ever want to.

---

## 9. Open questions

- IONOS fair-use terms for a box running near full port speed for weeks: the exact policy, and whether they will confirm in writing.
- IONOS images/cloning and whether a cloned box keeps anything that must be unique (SSH host keys, machine id, forwarder key): regenerate those on first boot regardless.
- IPv6 on IONOS boxes (the peer lock and CAKE both handle v6 today).
- APAC: an OVH region or a local host, and whether one region box is enough at first.
- Whether the relay should also move file relay traffic to nodes, or leave files on the control box (they ride WS today).
- The exact load number the forwarder reports and how often, without it becoming a per-stream signal.
