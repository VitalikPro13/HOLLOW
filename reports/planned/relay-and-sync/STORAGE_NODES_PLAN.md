# Storage nodes: volunteer and self-hosted storage for servers and people

**Status:** PLANNED. Design drafted 2026-09-17 (Vitalik + Fable session) from three research passes (Cloudflare docs, self-hosted storage, the vault and fetch code as it stands). Nothing built. Vitalik's decisions on the open points folded in the same day (section 15).
**Owner:** Vitalik (architect).
**Companion memory:** `project_r2_decision` (Hollow never hosts; the 2026-09-06 bring-your-own-bucket decision this supersedes in shape but not in principle), `project_federation_decision` (hosting is not trusting), `project_relay_availability_cache` (what the relay rings hold, and the parked per-server storage idea), `project_file_card_honest_states` (the card states a node joins), `project_autodownload_gate`, `project_at_rest_file_encryption_plan`, `feedback_share_backed_files`.
**Plan checklist:** HOLLOW_PLAN.md, the "Volunteer full-file storage pool" item (this document is its design; rewrite the bullet when phase 1 starts).
**Related plan:** `reports/planned/relay-and-sync/MULTI_RELAY_CLIENT_PLAN.md` (a self-hosted relay and its storage node are configured side by side; nothing here depends on multi-relay).

---

## 0. TL;DR

Hollow has no CDN and never will host anyone's files. Today a file is available only while someone who holds it is online, and large media (video above all) depends on home upload speeds. The vault helps durability on 6+ member servers, but it cannot give availability: its holders are the same home connections.

The answer is **storage nodes**: always-on holders of encrypted blobs that members bring. One protocol, two backends:

1. **Volunteer Cloudflare node.** A member connects their own Cloudflare account. Hollow deploys a small Worker in front of an R2 bucket in that account. Only the Worker can touch the bucket; members never see an R2 credential. The Worker enforces the quota the volunteer chose, evicts the oldest blobs when full, accepts writes only with a valid server pass, and keeps every billable counter inside the free tier, so the volunteer's bill stays at zero even under abuse.
2. **Self-hosted node.** `hollow-blobd`, a small Rust service that stores blobs as files on disk with a SQLite index. It ships as an optional service in the self-hosted relay compose and as a container for a NAS. Same protocol, same passes, same quota and eviction.

Nodes serve two scopes:

- **Server pool:** any member can add a node to a server, the way anyone can boost a Discord server. Each blob lives on one node by default (full capacity); the owner can keep up to five extra copies, and the storage page shows what that costs in capacity. Ten volunteers at 9.5 GB each is about 95 GB, online around the clock even while the ten people are asleep, with free egress. A volunteer who retreats hands their files to the other nodes first.
- **Personal node:** your own node for your outgoing media. It carries DM attachments to offline friends, fills a newly linked device's history, and lifts the 34 MB direct-send limit.

Nodes are dumb and untrusted. The client encrypts, chooses placement, and verifies every byte it reads. A node sees opaque ciphertext under a random-looking name and never a key, a member name, a server name or a message.

Decision summary:

- **Hollow still hosts nothing.** Every node belongs to a member. The relay keeps zero storage.
- **One protocol (HBP, Hollow Blob Protocol)** for both backends, modeled on Blossom's shape (GET by hash, range reads) with Hollow's own authorization.
- **Blobs are chunked ciphertext** with a stable id, so any node can serve any range and any client can verify it. This is a new at-rest-independent format; the FileHeader gains a `blob` reference.
- **Reads need no signature.** Knowing a 256-bit blob id is the capability. **Writes need a pass**, which every member's client gets automatically from the owner or an admin.
- **Budgets live in the Worker, not in Cloudflare:** Cloudflare has no spend cap for R2 and budget alerts only send email. The Worker plus the free Workers plan's hard daily request limit are what make zero billing true.
- **Whole blobs, no erasure coding** on nodes (range reads and simple repair). The vault stays for servers without nodes. **Nodes replace Share** up to a per-server size limit (100 MB by default, up to 500 MB).
- **Allowed by default, asked once per conversation:** before the first fetch from a node in a DM or server, a dialog explains what the node's provider sees and offers to keep nodes off for that conversation.

---

## 1. Today, precisely

Facts from the code on 2026-09-17 that this design depends on.

### 1.1 Where files live

- **DMs:** the sender's disk, the recipient's devices, our own siblings (`node/file_asks.rs:112-133`). No vault. An offline recipient gets a small image inlined into the header and buffered by the relay (`file_handler.rs:1381`), or a metadata-only header for anything else, pulled later from the sender.
- **Servers under 6 members:** full streaming to online members (`file_handler.rs:1875`). No vault.
- **Servers of 6+ members:** Dart starts a vault upload for every file (`file_transfer_provider.dart:231,310`); Rust Reed-Solomon codes it (`vault/adaptive.rs:20-29`, 3+2 at 6 to 8 members up to 20+10) and places shards by XOR distance weighted by pledges (`vault/placement.rs:20-51`). Non-image files on 6+ member servers are vault-only: the sender keeps no full copy (`file_handler.rs:1609`).
- **Files over 34 MB:** a hidden Hollow Share, chunked P2P, STUN-only (`node/share_handler.rs`).
- **The relay rings** hold headers and small inline DM images only, in RAM, with a 512 MB global budget (`relay-uws/src/state.h`).

### 1.2 What the vault cannot do

These are the gaps a node pool closes; they are recorded here, not fixed by this plan.

- A holder offline at upload is skipped and never retried (`vault_ops.rs:386`).
- The manifest (key, nonce, content id) goes out as a room broadcast to members online at upload; there is no manifest sync (`vault_ops.rs:427-465`), so a member offline then never learns it.
- Repair computes new targets but never re-encodes or re-places (`vault/rebalancer.rs:117`, `new_targets` unused).
- Pledges weight placement but are never enforced as a quota, and held shards are never evicted.
- Reconstruction needs k holders online at the same time.

### 1.3 The wire has no stable content hash

`FileHeaderPayload` (`node/types.rs:2835-2896`) carries the AES key and nonce but no hash. Every holder that re-serves a file re-encrypts it with a fresh key (`swarm.rs:13716`), so ciphertext is not stable across holders. Integrity today is the GCM tag against the header in hand. A node needs a stable ciphertext and a hash to verify against, so the blob format below is new.

### 1.4 Server secrets

CRDT server settings are never secret: every setting change also goes out as a plaintext `CrdtOpBroadcast` twin (`sync_handler.rs:137-159`). Secrets ride MLS (plus Olm to members without a leaf), the way the vault manifest does, or are derived from the MLS export secret, the way SFrame keys are (`crypto/mls_manager.rs:630`).

### 1.5 Limits in force

34 MiB direct send (`node/file_transfer.rs:6`), server `max_file_size_mb` default 34 enforced at the sender and both receivers (`file_handler.rs:303,2900`, `swarm.rs:8264`), relay payload 64 MiB, local caches: downloads 5120 MB, vault cache 1024 MB, assets 512 MB, evicted oldest first (`vault/pipeline.rs:307`).

---

## 2. Research findings that shape the design

### 2.1 Cloudflare (checked against official docs 2026-09-17)

| Fact | Consequence |
|---|---|
| R2 API tokens scope to buckets and a permission level only; no size or write limit on a token. Temporary credentials add prefixes and a TTL but must be minted with the owner's API access. | No member can be given a limited R2 credential. Only a Worker can enforce limits. |
| R2 bucket storage is unlimited; no per-bucket quota. Lifecycle rules delete by age, prefix or date, run "within 24 hours", never by size. | Quota and eviction are the Worker's job. |
| No spend cap for R2. Budget alerts (added 2026-04-13) are "informational only. They do not pause or cap usage." Enabling R2 is a pay-as-you-go subscription; a card is required in practice. | Zero billing must be engineered: storage under 10 GB-month, Class A under 1M a month, Class B under 10M a month. |
| R2 free tier: 10 GB-month storage, 1M Class A, 10M Class B per month, egress free (including through the Workers API). Delete and abort are free. Every `put`, `uploadPart` and `list` is Class A; `get` and `head` are Class B. | Eviction costs nothing. `list` never runs on a hot path. |
| Workers Free plan: 100,000 requests a day, then Error 1027; a Free account is never billed for Workers. 10 ms CPU per request, 50 subrequests, request body up to 100 MB on Free. No egress charge. | The daily request ceiling is the backstop that bounds everything. Uploads over 100 MB use multipart. The Worker never hashes a large body (CPU). |
| SQLite-backed Durable Objects are available on Free (100,000 requests, 100,000 rows written a day, 5 GB), failing with errors when exceeded, never billing. A Durable Object processes calls one at a time. | One Durable Object per node is the race-free quota and budget authority. |
| R2 `put` needs a stream of known length. `get` accepts a range and conditional headers; a Worker can return 206 with a streaming body. Multipart parts are at least 5 MiB, uniform except the last, up to 10,000 parts. Unfinished uploads expire after 7 days by default. | Uploads require Content-Length. Range reads are native. In-flight multipart bytes count against the quota. |
| A script can be deployed by API (`PUT /accounts/{id}/workers/scripts/{name}`, multipart metadata with `r2_bucket`, `secret_text` and Durable Object bindings), the bucket created by API, the workers.dev subdomain enabled by API. A pre-filled token link is documented (`permissionGroupKeys`), with `workers_scripts` and `workers_r2` edit. | One-click setup inside Hollow is possible: open a link, approve, paste the token and account id. |
| Ed25519 verification is native in Workers Web Crypto; `timingSafeEqual` exists. | Pass and request signatures verify inside the 10 ms budget. |
| Developer Platform terms: "can be used to host content"; the CDN video restriction targets the plain CDN, not Workers and R2. Cloudflare may limit or suspend for illegal content or undue load; the account holder is responsible. Cloudflare may change workers.dev subdomains "for any or no reason". | Allowed. The volunteer carries account risk and must be told. Node endpoints are data, never identity. |
| workers.dev is throttled or polluted in some countries (Russia throttles Cloudflare traffic to 16 KB per connection since June 2025; mainland China DNS reports). | Nodes are never the only source. Peers and the vault stay in the ladder. |

Unconfirmed (verify during phase 2): the rate limiting binding on the Free plan, whether unfinished multipart parts bill as storage (assume yes), the exact Class A or B mapping of each binding method (strongly implied), and the freshness of R2 storage metrics (not used).

### 2.2 Self-hosted storage

- **MinIO is out:** the community repository is archived, source only, no longer maintained; the free successor is proprietary and single node.
- **A plain filesystem store is the right single-node default.** No S3 server evicts by size (Garage quotas reject writes; lifecycle rules are age based), so the gatekeeper needs its own size index in every design, and an S3 layer would only add a daemon, credentials and a second auth scheme.
- **Garage** (AGPL-3.0, v2.4.1, active) is the one mature choice for pooling several small machines across locations: 1 GB RAM, mixed hardware, replication factor 3 recommended, 3 nodes minimum. It is an optional backend, not the default.
- **versitygw** (Apache-2.0) is the choice for a NAS owner who wants S3 over existing storage. **RustFS** reached 1.0 on 2026-09-16 and is too new. **rclone serve s3** is experimental.
- **Reaching a NAS:** IPv6 or a port forward with a DuckDNS name and a Let's Encrypt certificate (as the relay guide already does), Tailscale Funnel as the no-port-forward fallback (beta, unpublished bandwidth limits), Cloudflare Tunnel only with a warning (its video terms apply to tunnel traffic on free plans, and uploads cap at 100 MB per request). Residential upload speed is the real ceiling for video; a NAS is a holder, never the only source.
- **Prior art:** Blossom (nostr) stores blobs by sha256 with `GET /<sha256>`, range support and signed expiring authorization, and mirrors blobs across a user's server list. HBP borrows its shape. Tahoe-LAFS and Storj confirm the model: the client encrypts and places, servers are untrusted, pools need explicit uptime expectations and automatic repair.

---

## 3. Non-goals

- **No Hollow-operated storage**, on the official relay or anywhere else. The `project_r2_decision` principle stands.
- **No pooled R2 credentials.** Nobody ever holds a credential to anyone else's bucket.
- **No erasure coding across nodes** in this plan. Whole blobs keep range reads and repair simple; erasure coding stays the vault's.
- **No message storage on nodes.** Text stays peer-held plus the relay rings. Only file bytes.
- **No relay proxying of node traffic.** Clients talk to nodes directly.
- **No streaming protocol of our own.** HTTP range requests are the streaming protocol.
- **No federation.** A node is a holder for a server or a person, not an independent server.

---

## 4. The blob

### 4.1 Format

A blob is one file's ciphertext in fixed chunks, so any byte range can be fetched and decrypted without the rest.

- **Blob key:** a fresh random 32-byte key per file, generated by the sender. It rides the FileHeader inside MLS or Olm, exactly as `aes_key` does today.
- **Chunks:** plaintext split into 1 MiB chunks; each sealed with AES-256-GCM under the blob key with a nonce derived from the chunk index (`nonce = file_nonce_prefix(8) || index_be(4)`), the last chunk flagged in the associated data so truncation fails. Ciphertext chunk = 1 MiB + 16-byte tag, so chunk `i` starts at byte `i * (1 MiB + 16)`.
- **Blob id:** SHA-256 over the concatenation of the per-chunk ciphertext SHA-256 values (a flat hash list, like the Share manifest). Hex, 64 characters. Because the key is random per file, two uploads of the same plaintext have unrelated ids: the id identifies ciphertext, never content.
- **Index object:** the list of chunk hashes, stored on the node as `<blob id>.idx` (32 bytes per chunk: 2,048 chunks for a 2 GB video is 64 KB). A reader fetches the index once, checks it hashes to the blob id, then verifies each chunk it reads.

Why chunks of 1 MiB: a seek costs at most one extra chunk, a Worker range read stays small, and the index stays tiny. The Share format (256 KiB chunks, its own manifest and per-share key) stays separate: nodes replace Share below the size limit, and Share keeps serving what is larger (decision 6).

### 4.2 On the wire

`FileHeaderPayload` gains `#[serde(default, skip_serializing_if = "Option::is_none")] pub blob: Option<Box<BlobRef>>` (boxed from day one: `feedback_type_growth_blows_tokio_stack`), and the same on `SyncFileMetaItem` and the public file metadata.

```
BlobRef {
  id:     String,        // 64 hex, the blob id
  key:    String,        // 64 hex, the blob key (only ever inside MLS/Olm)
  nonce:  String,        // 16 hex, the nonce prefix
  size:   u64,           // plaintext bytes
  scope:  "server" | "personal",
  nodes:  Vec<String>,   // node ids the sender placed it on (a hint, not authority)
}
```

The existing fields stay. A receiver that knows `blob` can fetch from nodes; one that does not falls back to today's paths. The `blob` field is inside the MLS or Olm payload, so the relay never sees it.

**Signing (decided: extend).** The blob id and its size are bound into the message signature, so no holder can later point a message at different bytes. Rather than a new prefix per new field (v3 exists only for `album`), v4 ends the per-field versions:

```
hollow-msg4:{type}:{context}:{sender}:{ts}:{mid}:{extras_digest}:{text}
extras_digest = hex SHA-256 over length-prefixed (name, value) pairs, sorted by name,
                for every present optional field: reply_to, file_id, order_us, lp,
                album, blob_id, blob_size, and any field added later
```

`sign_message_versioned` signs v4 whenever the message carries any field v2 and v3 cannot express (today: a blob), v3 when only an album is present, v2 otherwise, so every existing message stays byte-identical. The verifier picks the version from which fields the payload carries, as v3 does. A future field joins the digest without a new version. Length prefixes make field boundaries unambiguous, so no shape restriction is needed on values inside the digest.

### 4.3 Local storage

Decrypted chunks are written through `at_rest::Writer` as the download progresses, so a partially watched video is a partial at-rest file, completed in the background or evicted like any download (`project_at_rest_file_encryption_plan`).

---

## 5. HBP, the Hollow Blob Protocol

HTTPS only. JSON errors. Every response carries `Cache-Control: private, no-store` except blob and index bodies, which are immutable (`Cache-Control: public, max-age=31536000, immutable`: a CDN caching ciphertext by id leaks nothing new).

| Method | Path | Auth | What |
|---|---|---|---|
| `GET` / `HEAD` | `/b/<id>` | none | Blob bytes. `Range: bytes=a-b` gives 206 with `Content-Range`; single range only. `Accept-Ranges: bytes`. 404 if absent or evicted. |
| `GET` | `/b/<id>.idx` | none | The chunk hash list. |
| `PUT` | `/b/<id>` | pass + request signature | Upload up to 95 MiB in one request. `Content-Length` required. Body = ciphertext. Header `Hbp-Index` carries the index object (base64) for small blobs. |
| `POST` | `/m/<id>` | pass + signature | Start a multipart upload for larger blobs. Declares the total size, reserves quota, returns an upload id and part size (16 MiB). |
| `PUT` | `/m/<id>/<upload>/<n>` | pass + signature | Upload part `n`. |
| `POST` | `/m/<id>/<upload>/done` | pass + signature | Complete with the index object. |
| `DELETE` | `/b/<id>` | pass + signature | Delete. Allowed for the pass that uploaded the blob, or an admin pass. |
| `GET` | `/status` | none | Signed by the node key: `{version, scope, plan: free\|paid, quota_bytes, used_bytes, reserved_bytes, accepting, evicted_count, oldest_retained_upload, class_a_month, class_b_month_approx, writes_left_today}`. Clients cache it for 10 minutes. |
| `POST` | `/admin/config` | authority signature | Replace the authority key set, pass revocations, quota (within the volunteer's ceiling), eviction mode. |

### 5.1 Why reads are open

A blob id is 256 bits of hash over random-keyed ciphertext; guessing one is infeasible, and a leaked id reveals only ciphertext. Requiring signatures on reads would not protect the node anyway: an invalid signature still costs a Worker request, so it spends the same daily budget as a valid read. What reads cost is bounded separately (section 7.2).

### 5.2 Passes

A **pass** authorizes writes. Every member gets one; nobody applies for it.

```
StoragePass {
  v: 1,
  scope: "server:<server_id_hash>" | "personal:<master_id_hash>",
  device: <device Ed25519 public key>,
  issued_at, expires_at,          // 30 days
  class: "member" | "admin" | "handoff",
  issuer: <authority public key>,
  sig: Ed25519(authority, canonical bytes)
}
```

- `server_id_hash = SHA-256("hollow-hbp-scope" || server_id)`, so the node never learns the server id. Same for the master id on personal nodes.
- **Authorities (server scope):** the owner's master key and the admins' master keys. Whoever adds a node writes the current set into it; when roles change, any admin device online pushes the new set through `/admin/config`, which a node accepts when signed by a current authority or by the node's operator.
- **Issuing:** any online owner or admin device grants passes automatically to members who ask (new `MessageEnvelope::StoragePassRequest` / `StoragePassGrant` over MLS, owner handler in a new `node/storage_nodes.rs`). A client asks when it has no pass or under 7 days left. The grant checks membership and `op_allowed` for posting files, nothing else: there is no human approval.
- **Authorities (personal scope):** your master key; passes for your own devices only.
- **Each request** carries `Hbp-Pass` (base64 pass) and `Hbp-Sig` = Ed25519 by the device over `method || path || content_length || unix_minute || nonce`, with `Hbp-Time` and `Hbp-Nonce`. The node rejects a time more than 5 minutes off, and replays within the window (the node authority keeps recent nonces for write paths).
- **Revocation:** when a member is removed or banned, the next admin device online pushes the pass device key into the node's revocation list (kept until the pass would have expired). Until then a removed member is bounded by the per-pass limits in 7.3.

### 5.3 Why not SigV4 or Blossom auth

SigV4 would tie the protocol to S3 and needs a shared secret on every member device. Blossom's kind-24242 nostr events would pull nostr identity and event encoding into Hollow. Ed25519 passes reuse the identity keys Hollow already has and verify natively in both backends.

---

## 6. The server pool

### 6.1 Registry

A server's nodes are a replicated, signed list that every active member converges on, the way CRDT state converges, but carried only inside encrypted envelopes. It is deliberately not a server setting: settings also travel as a plaintext twin and sync to public-channel guests (section 1.4), and a node's endpoint is exactly what someone flooding it with requests would want.

```
StorageNodeRecord {
  node_id: SHA-256(endpoint_origin || node_public_key)[..16],
  endpoint: "https://<name>.workers.dev" | "https://storage.example.org",
  node_public_key,           // the node signs /status, so a swapped endpoint is detected
  backend: "cloudflare" | "blobd" | "blobd-s3",
  operator: <member master id>,
  quota_bytes,
  accepts_handoff: bool,     // takes files from a retreating node (6.6)
  state: "active" | "draining" | "retired",
  version, updated_at,
  sig: Ed25519(operator master key)
}
```

- **Who adds:** any member, like a Discord boost. No approval. The operator signs their own record; last writer wins per `node_id` by `(version, updated_at)`, and only the operator (or the owner, to remove an abusive node) can change it.
- **Distribution:** MLS broadcast plus Olm to members without a leaf, the vault manifest path, **with sync**: the registry is part of the join bootstrap and any member answers `StorageRegistryRequest`, so an offline member catches up (the vault manifest's missing sync is not repeated).
- **The storage dashboard** (server settings > Storage, visible to every member): each node's operator, backend, plan, quota, used, free, uptime, health and flags from the pool checks (6.7), placement priority, this month's storage and operation counts with the estimated cost (7.4), state, and the pool's totals: capacity at the current copy setting, used, and estimated monthly cost. Good faith is the model; the dashboard is what makes it loud when a node misbehaves.

### 6.2 Placement

- **Extra copies:** a server setting from 0 to 5, default 0 (every node's space counts once, full capacity). The Storage page shows the resulting capacity live ("95 GB of files at 0 extra copies, 47 GB at 1"). This setting is not secret and may be a CRDT setting. With 0 extra copies, a node that vanishes takes its files out of the pool; peers, the vault and readers repair (6.4) are what remains, and retreating nodes hand off first (6.6).
- **Choice:** weighted rendezvous hashing over `(blob id, node id)`, skipping nodes that are draining, not accepting, or have under 2x the blob size free. Deterministic, so every member computes the same order without coordination, and adding a node moves only the blobs that now prefer it.
- **Priority is proportional to what a volunteer gives.** A node's weight is its donated quota, so a 1 TB node receives about a hundred times the new files a 9.5 GB node does, and space fills evenly in proportion rather than node by node. The weight is then multiplied by:
  - **health** from the pool checks (6.7): 1 when clean, 0.5 during a new node's first 24 hours, 0.01 while flagged (lowest priority, still readable);
  - **free-tier headroom** for nodes on the free plan only: 1 until 80 percent of the month's free Class A operations are used, then falling linearly to 0.1 at 100 percent, so a volunteer who chose to stay free is never pushed into paying. Nodes the volunteer already pays for (quota above 10 GB or a paid plan) are not scaled by it.
- **The black-hole node.** Because anyone can add a node, a member could add one that accepts uploads and discards them, or empties itself later. The pool checks (6.7) catch that within 30 minutes and push the node to the bottom of the order; its first-day half weight limits what a brand-new bad node can swallow before the first check.
- **Who uploads:** the sender, in the background after the message is sent (the vault upload's slot in `file_transfer_provider.dart`). The header goes out immediately with `blob` and the planned `nodes`; receivers fetch from peers until a node has it.
- **Ordering:** nodes before the vault. When a server has at least one healthy node with room, new files skip the vault upload; the sender keeps its full local copy (the vault-only path in `file_handler.rs:1609` is not taken).

### 6.3 Fetch ladder

For a file with a `blob` reference:

1. **Local disk.**
2. **Storage nodes**, unless nodes are off for this conversation (section 11): parallel `HEAD` to the hinted nodes and the top two by rendezvous order, then `GET` from the first that answers, falling over per chunk.
3. **Online peers** through `file_asks.rs`, unchanged.
4. **The vault**, for files that were vault-uploaded (old files, or servers without enough nodes).
5. **Share swarm**, for share-backed files.

Nodes come before peers when enabled because they are the fast, always-on path and cost no member's upload bandwidth. The auto-download gate applies unchanged: a node is just a faster holder.

**Card states:** `file_card_status.dart` gains one caption, shown only when every source failed and at least one node was tried: "Not stored for this server any more" when nodes answered 404, "Storage for this server is unreachable" when they could not be reached. Both keep the retry control.

### 6.4 Repair and rebalance

- **Readers repair:** when a client holds a whole file and finds it missing on the node rendezvous order says should hold it, it re-uploads in the background, one blob a minute per client at most. Content stays alive while anyone still watches it.
- **Eviction is honest:** a node that evicted a blob returns 404; the card states handle it. A pool is a cache for availability, never the authority.

### 6.5 File policy

- **Size limit for node-backed files:** a server setting, 100 MB by default when the server has nodes, adjustable by owners and admins up to 500 MB. A file under the limit is a blob on a node and never a Share. A file over the limit is still offered as a Hollow Share, as today. Personal nodes have the same default and ceiling, set by their owner. The ceiling is a code constant raised on request, not a setting.
- **File types:** all kinds by default (images, video, audio, PDFs, archives, anything). Owners and admins can block categories (video, audio, archives, executables, documents) or extensions in the Storage page; blocked files are never placed on nodes and fall back to peers. Enforced by the uploading client, since a node only ever sees ciphertext: the same trust level as every other posting rule a modified client could ignore.
- Both settings are CRDT server settings (not secret).

### 6.6 Retreating and hand-off

A volunteer stops donating from the Storage page:

1. **Choose:** "Hand my files to the other nodes" (default) or "Just stop". The dialog shows how much the nodes with `accepts_handoff` can take right now.
2. **Draining:** the operator's client republishes the record with `state: draining`. Clients stop placing on it immediately; it keeps serving reads.
3. **Hand-off:** the node itself copies its blobs to accepting nodes in rendezvous order, oldest last so the newest media survives a shortfall. On Cloudflare a Durable Object alarm moves a batch per run within the Worker's subrequest and budget limits (a stream from R2 to the target's `PUT`, no CPU-bound work); on blobd a background task does it. The node writes with a **hand-off pass**: class `handoff`, bound to the retreating node's own key, requested by the operator's client through the normal pass request and granted by any online owner or admin device, valid 14 days. Receiving nodes apply their quota and replay rules but not the member's daily byte limit, so a full 9.5 GB node empties in a day or two rather than ten. Receivers need no action: `accepts_handoff` is their consent, on by default and switchable by their operator.
4. **Done:** when the node holds nothing, or the hand-off stops making progress for a day, the operator's client republishes `state: retired`, deletes the Worker and the bucket (delete is free) with the stored token, and the record stays in the registry as retired so the dashboard keeps the history.

"Just stop" skips step 3. Files that no other holder has are then gone from the pool, and their cards say so.

### 6.7 Pool health checks

- **When:** on the existing 30-minute vault timer (`node/swarm.rs:1184`), for every server with registered nodes.
- **Who:** one checker per server, not every member: the same election the vault coordinator uses (`crypto_handler.rs:2174`, lowest online peer id). A thousand members each checking ten nodes every half hour would be 480,000 requests a day and exhaust every free node; one checker is about 430 requests a day per node.
- **What, per node:**
  1. `GET /status` and verify its node signature.
  2. **Spot checks:** `HEAD` on 8 blob ids placed on that node, drawn from the checker's own record of placements it has seen in message headers (weighted toward the last 7 days, where deletion hurts most).
- **Eviction or deletion.** A full node is allowed to drop its oldest blobs; that is the quota working, not misbehaviour. `/status` reports `evicted_count` and `oldest_retained_upload`, so the checker can tell the two apart: a missing blob uploaded **before** `oldest_retained_upload` was evicted and is fine; a missing blob uploaded **after** it was deleted or never stored.
- **Verdicts:**
  - **Clean:** status verified and no unexplained misses.
  - **Unreachable:** status failed. Three in a row (90 minutes) marks the node offline in the dashboard and removes it from placement until it answers again. Reads still try it last.
  - **Flagged:** any unexplained miss in two checks in a row. The dashboard shows it in red at the top of the Storage page with the evidence ("6 of 8 recent files missing that this node should still have, 14:30 and 15:00") next to the operator's name, every member sees it, and its placement weight drops to 0.01 until four clean checks in a row (two hours) clear the flag.
  - A signature mismatch on `/status` flags immediately: the endpoint no longer belongs to the registered node.
- **Sharing:** the checker publishes a signed `StorageHealthReport { node_id, verdict, evidence, checked_at }` over MLS to the server group. Every member applies the latest report per node to its placement weights and dashboard, so all clients agree. A report from a checker that is not the current elected checker, or older than an applied one, is ignored.
- **Readers add evidence:** a client that gets a 404 for a blob uploaded after the node's last `oldest_retained_upload` counts it locally and includes the count when it becomes the checker, so a node deleting files between checks does not hide behind sampling.
- **Cost:** about 48 status reads and 384 heads a day per node, all Class B, free on every node.

## 7. Quota, eviction and billing guards

### 7.1 Quota and eviction (both backends)

- **Accounting:** a single authority per node (the Durable Object on Cloudflare, SQLite on blobd) holds `blobs(id, size, uploaded_at, uploader, last_read_day)` and `reservations(upload, bytes, expires_at)`.
- **Reserve before write:** a write reserves its full size first. If `used + reserved + size > quota`, the node evicts oldest first until it fits, then reserves; if it still cannot fit (the blob is larger than the quota), 413.
- **Eviction order:** oldest `uploaded_at` first (what Vitalik asked for: new media replaces old). `last_read_day` is recorded at most once per day per blob and breaks ties, so a video watched today outlives an unwatched one uploaded the same day. On Cloudflare the day-bucket write is skipped when the Durable Object's write budget is under 20 percent.
- **Multipart:** the declared total is reserved at start; a Durable Object alarm aborts uploads idle for 6 hours and releases their reservation (abort is free on R2).
- **Reconciliation:** once a week the node lists its storage (R2 `list` pages, capped at 20 pages a run) and repairs the index.

### 7.2 Cloudflare billing guards (the zero-bill guarantee)

The volunteer's quota defaults to **9.5 GB**, and every reserved byte (index objects, in-flight multipart parts) counts inside it, so the free tier's 10 GB-month is never reached. They can change it:

- **Below 9.5 GB:** no question.
- **9.5 to 10 GB:** "Are you sure? This is close to the free limit, and a busy month could cost a few cents." The Worker then keeps a 50 MB reserve for in-flight work below the chosen number.
- **Above 10 GB:** a cost estimate before saving: "About $X a month at full use", from R2's Standard storage price. The app ships the documented price ($0.015 per GB-month as of 2026-09-17) and links Cloudflare's pricing page. Whether an API returns list prices, or the account's current usage, is checked in phase 3 (the billable usage dashboard is new since 2026-04-13); if one exists, the estimate uses it.

| Counter | Where | Limit | Why it holds |
|---|---|---|---|
| Stored + reserved bytes | Durable Object | the quota, 9.5 GB by default | Reserve before write; eviction is free. |
| Class A operations (put, uploadPart, create, complete, list) | Durable Object, per UTC day | 30,000 a day | 31 x 30,000 = 930,000, under 1M a month. A write request that would exceed it gets 429 `writes_exhausted` before touching R2. |
| Class B operations (get, head) | implicit | at most 100,000 a day | The Workers Free daily limit caps requests; 31 x 100,000 = 3.1M, under 10M. |
| Worker requests | Cloudflare | 100,000 a day, then Error 1027 | Free plan; never billed. |
| Durable Object requests and row writes | Cloudflare | 100,000 a day each | Only write paths and the once-a-day read stamp touch the Durable Object; reads do not. |

- **Fail closed:** the Worker is deployed with the fail-closed setting, so exceeding the daily limit returns 1027 instead of bypassing the Worker.
- **Paid plan detection:** if the volunteer's account is on Workers Paid, the 100,000 ceiling disappears. Setup detects the plan through the API and, on Paid, deploys the Worker with its own request budget in the Durable Object for reads too (every read then costs a Durable Object request, still within Paid allowances), and shows the volunteer that reads are now capped by the Worker instead of by Cloudflare.
- **What an attacker can do:** spend the node's daily requests (downloads fail until midnight UTC, free), spend its daily writes (uploads fail until midnight UTC, free), fill its quota with junk if they hold a valid pass (bounded by 7.3, oldest media evicted, free). They cannot cause a charge.
- **What can still bill:** the volunteer raising the quota past 10 GB after the estimate, or editing the Worker's budgets by hand. Budget alerts should still be left on as a second line.

### 7.3 Per-pass limits (abuse by members)

Kept by the node authority per pass device key, per UTC day:

- **Bytes written:** 1 GiB a day for `member`, unlimited for `admin` (still under the quota).
- **Write requests:** 500 a day for `member`.
- **Deletes:** own blobs only for `member`.

A removed member with an unexpired pass can therefore push out at most 1 GiB of old media a day per node until revocation lands. The rate limiting binding, if it proves available on the Free plan, is added as a cheap first filter in front of the Durable Object for write paths.

---

### 7.4 Cost accounting

Counted on every node and shown on the dashboard, per node and for the pool, so nobody is surprised even though a free node realistically never gets near the operation limits.

- **Prices used** (R2 Standard, as of 2026-09-17, shipped in the app and updated with releases): storage $0.015 per GB-month beyond 10 GB-month free; Class A (writes: put, multipart create, part upload, complete, list) $4.50 per million beyond 1 million free a month; Class B (reads: get, head) $0.36 per million beyond 10 million free a month; egress free.
- **Counters:** `used_bytes` averaged over the month so far; `class_a_month` exact (every write passes the node authority); `class_b_month_approx` from reads batched into the authority every 100 reads or 60 seconds, which is approximate by design so reads never cost a Durable Object request each.
- **Estimate:** `max(0, avg_GB - 10) x 0.015 + max(0, class_a - 1M) x 4.50/1M + max(0, class_b - 10M) x 0.36/1M`, projected to month end from the pace so far. Shown per node, summed for the pool.
- **The above-10-GB dialog** (7.2) uses the same prices for the storage part and adds the operation part at the pool's current per-GB pace.
- **In placement:** the free-tier headroom factor (6.2) reads `class_a_month`, so writes shift to other nodes before a free node would start paying.
- **blobd nodes** report sizes and request counts but no price: the operator's hosting cost is theirs to judge.

## 8. The Cloudflare backend

### 8.1 What gets deployed

One Worker script (ES module, a few hundred lines) and one SQLite-backed Durable Object class, bundled inside the app as a versioned asset so setup needs no download and the code a volunteer runs is the code in the Hollow repository (`storage-worker/` at the repo root, built to a single file checked into `assets/storage_worker/`).

- **Bindings:** `BLOBS` (R2 bucket), `LEDGER` (Durable Object namespace, `new_sqlite_classes` migration), `AUTHORITY` (secret: the authority key set and scope hash), `NODE_KEY` (secret: the node's Ed25519 private key for signing `/status`), `QUOTA_BYTES`, `CLASS_A_DAILY`.
- **Bucket:** Standard storage class (the free tier does not cover Infrequent Access), with a lifecycle rule aborting incomplete multipart uploads after 1 day and nothing else.
- **Reads:** straight from R2 with `get(key, { range, onlyIf })`, 206 with a computed `Content-Range`. No Durable Object call on the read path except the daily read stamp.
- **Writes:** verify pass and signature (Web Crypto Ed25519), ask the Durable Object to reserve, wrap the body in a `FixedLengthStream` of the declared length, `put`, then commit (or release on failure). The Worker never hashes the body: the id is the client's claim and every reader verifies chunks against the index, so a lying uploader only wastes its own pass budget.

### 8.2 Setup inside Hollow

A "Donate storage" flow in the server settings Storage page (and in Settings > Storage for a personal node):

1. **Explain first:** what a node is, that the volunteer needs a Cloudflare account and must add a card to enable R2 even to stay free, that Cloudflare will see their account holding encrypted files and the IP addresses of members who download them, and that they are the account holder in Cloudflare's terms. Sepia-reviewed copy.
2. **Open the pre-filled token link** (`permissionGroupKeys` = `workers_scripts` edit, `workers_r2` edit, `account_settings` read). The volunteer approves and pastes the token. Hollow reads the account id with it.
3. **Hollow checks R2 is enabled** (bucket list call). If not, it shows the one dashboard step and waits.
4. **Hollow creates** the bucket (random name), uploads the Worker with its secrets, enables the workers.dev route, sets fail closed, reads `/status` back and verifies the node signature.
5. **Registers** the node record (6.1) for the server or as the personal node.
6. **The token is the volunteer's own key to their Cloudflare account, never the pool's.** Members never see it and never need it: they reach the node through the Worker with passes, and the node runs around the clock without it. Hollow keeps it only on the volunteer's own device, encrypted in the CryptoStore, because updating the Worker and retreating (6.6) need it. The Storage page shows it with a "Revoke" action and says plainly that whoever holds it controls the bucket, quota included.

Updates: a new Worker version in a Hollow release shows "Storage node update available" to the operator, one tap with the stored or re-pasted token.

Removal: "Stop donating" marks the record removed, deletes the Worker and empties and deletes the bucket (delete is free).

### 8.3 Endpoint stability

workers.dev names can change at Cloudflare's discretion. The node record carries the node's public key, and `/status` is signed with it, so an operator can move the endpoint (a new workers.dev name or a custom domain) and re-publish the record without losing the node's identity or its blobs.

---

## 9. The self-hosted backend: `hollow-blobd`

### 9.1 Shape

- **Rust, one binary, one container.** axum with `tower-http` file serving for range reads, `ed25519-dalek` for passes, `rusqlite` for the index, TLS through the existing certificate path when run beside the relay or behind a reverse proxy otherwise.
- **Layout:** `blobs/ab/cd/<id>` and `<id>.idx`, written to a temporary name and renamed into place. Plain files, so backups are `rsync`.
- **Config:** one `.env` block: `BLOBD_QUOTA_GB`, `BLOBD_AUTHORITY` (set by the admin flow over `/admin/config`), `BLOBD_PUBLIC_URL`, `BLOBD_DATA`.
- **Same limits as the Worker** minus the Cloudflare counters: quota, eviction, per-pass limits, replay window. No daily request cap by default; `BLOBD_READS_PER_MINUTE_PER_IP` optional.
- **Backends:** `fs` (default) and `s3` (Garage, versitygw, any S3), behind one trait, so a group pooling machines can run Garage and point one blobd at it.

### 9.2 Next to a self-hosted relay

An optional compose profile, `COMPOSE_PROFILES=storage` (the way `turn` enables coturn), with the certificate the relay already obtains and a `storage.` path or port on the same host. `relay-uws/SELF_HOSTING.md` gains a "Storage node" section. The relay binary itself does not change and never touches blobs.

### 9.3 On a NAS

The same image on Synology, TrueNAS or Unraid, pointed at a dataset. The guide recommends, in order: IPv6 or a port forward with DuckDNS and Let's Encrypt; Tailscale Funnel when no port can be opened; Cloudflare Tunnel only with the warning from 2.2. It states plainly that the member's home upload speed is every downloader's speed from that node, which is why a server wants more than one node and why owners can keep extra copies.

---

## 10. Personal nodes

The same protocol with `scope = personal`. One node per identity (a Cloudflare node or blobd), passes issued by the master key to the identity's own devices.

- **Outgoing media:** when a personal node is configured, every file you send is also placed there. For DMs this is the difference: the header reaches an offline friend through the relay, and they fetch the file from your node when they come online, with no need for you to be online. The inline-image and metadata-only offline paths (`file_handler.rs:1381`) become the fallback.
- **Multi-device history:** a newly linked device fetches old attachments from your node instead of waiting for a sibling to be online.
- **Large files:** a blob-backed send goes past the 34 MB direct limit up to the personal node's size limit (100 MB by default, up to 500 MB, section 6.5). Above it the large-file dialog offers a Hollow Share, as today.
- **Channels:** personal nodes also serve your channel posts, as an extra holder alongside the server pool; readers learn it from the `nodes` hint.
- **Privacy:** friends who fetch from your node reveal their IP to your node's provider, the same trade as a server node, under the same per-conversation choice.

---

## 11. Privacy

What each party learns:

| Party | Learns | Does not learn |
|---|---|---|
| Hollow, the relay | Nothing new: the `blob` field rides inside MLS or Olm, and clients reach nodes directly. | Endpoints, blob ids, sizes, whether a server uses nodes at all. |
| The node operator (a member) | Blob ids, sizes, upload and fetch times, fetching IPs, pass device keys (pseudonymous) and the scope hash. | Content, keys, names, which server, which messages. |
| The operator's provider (Cloudflare, a VPS host) | The operator's billing identity, blob sizes and ids, fetching IPs and times. | Content, keys, anything about the server. |
| Other members | The node registry: endpoints and operators' member ids. | Nothing about other members' reads. |

Consequences and rules:

- **Allowed by default, asked once per conversation.** The first time a DM or server would read from or write to a node, a dialog explains it before the connection is made: "This server keeps its files on storage run by its members. When you download or upload, the company hosting that storage sees your IP address. Nobody can see the files themselves." Choices: "Allow" (default) and "Don't use storage nodes here". The answer is remembered per conversation and changeable in that conversation's settings. Off means the client never contacts a node for that conversation; files then come from peers, the vault or Share, and the cards say so.
- **A global default in Settings > Privacy** ("Ask" by default, "Always allow", "Never") for people who want to decide once. All dialog copy goes through the Sepia pass.
- **Blob ids never reach anyone outside members:** they live only in encrypted headers, never in CRDT state, push payloads, logs or crash reports (a CI source scan like the existing guards forbids logging a blob id or endpoint URL in Rust `hollow_log!` lines).
- **Cloudflare sees a link it would not otherwise have:** this IP downloaded from this volunteer's account at this time, across every volunteer account it hosts. Cloudflare already sees much of the internet's traffic, so the added exposure is modest for most people; it is still why the dialog exists and self-hosted nodes are first-class.
- **VPN use is the user's business**, as with link previews.

---

## 12. Threat model

| Actor | Can | Cannot | Mitigation |
|---|---|---|---|
| Outsider with no pass | Spend a Cloudflare node's daily requests (downloads fail until midnight UTC); read a blob whose id leaked (ciphertext) | Write, delete, bill, decrypt | Free-plan ceiling, fail closed; ids never leave encrypted headers; replicas on other nodes |
| Member with a valid pass | Fill a node with junk and evict old media, up to 1 GiB a day per node; spend writes for the day | Delete others' blobs, bill, read anything they could not already | Per-pass limits, revocation, extra copies, readers repair |
| Removed member | The above until revocation lands or the pass expires (30 days) | Get a new pass | Admin devices push revocations on removal |
| Malicious operator | Delete or withhold everything on their node, accept uploads and discard them, log IPs and times, serve wrong bytes | Read content, forge a valid chunk | Pool health checks every 30 minutes and the loud dashboard flag at lowest priority (6.7), owner removal, extra copies if the owner sets them, per-chunk verification, readers repair, the per-conversation choice |
| Operator's provider | See identity of the operator, fetch metadata; suspend the account | Read content | Self-hosted alternative, extra copies, peers and vault in the ladder |
| Relay operator | Nothing new | See node traffic | Clients go direct |
| Network censor | Block workers.dev or throttle Cloudflare | Block peers and the vault path | Ladder falls back; self-hosted nodes on other networks |

---

## 13. Phasing

| Phase | Scope | Ships alone |
|---|---|---|
| 1 | Blob format, `BlobRef`, v4 signing, client chunked uploader and range fetcher with verification, the video loopback reading blobs by range, `hollow-blobd` with fs backend, passes for personal scope, the personal node end to end on desktop and mobile (DM offline delivery, sibling history, large files) | Yes. Smallest trust surface: one person, their own node. |
| 2 | Server pool: registry with sync and join bootstrap, server passes and reissue, placement with rendezvous hashing, the ladder change, card states, readers repair, the public storage dashboard (nodes, operators, capacity at the copy setting, health, priority, cost, add, remove), pool health checks on the 30-minute timer with shared reports, capacity-weighted priority, extra copies, file size and type policy, retreat with hand-off, the per-conversation dialog and global default, compose profile and NAS guide | Yes. Self-hosted pools work. |
| 3 | Cloudflare backend: the Worker and Durable Object, billing guards, one-click setup and update, paid-plan detection, endpoint moves | Yes. |
| 4 | Vault integration: skip vault uploads when a pool has enough nodes; measure what the vault still does; decide whether to keep it as the zero-setup tier or retire it. `s3` backend for blobd (Garage). | Each item alone. |

Mobile parity within each phase (`feedback_mobile_parity_always`), except setup of a self-hosted node, which is a desktop and server task.

---

## 14. Verification

- **Harness (Rust):** an in-process blobd on a loopback port per test. Personal node: DM to an offline friend delivered from the node after the sender goes offline; a linked sibling fills history from the node. Server pool: an album placed on one node, the node evicts, a reader holding the files repairs; a black-hole node that discards uploads is flagged and dropped from placement; a retreating node hands its blobs to an accepting node and retires; a removed member's pass is refused after revocation; a tampered chunk fails verification and the next node is tried.
- **Worker (JavaScript):** unit tests under the Workers test pool (Miniflare) for pass verification, replay window, reservation races (concurrent puts against one Durable Object), eviction order, multipart abort and release, every budget counter at its limit, fail-closed behaviour. These live in `storage-worker/` and run in CI.
- **blobd:** property tests for the quota under concurrent reserves, range responses against RFC 7233 cases, eviction ties.
- **Fleet:** a two-instance journey with a local blobd (video posted, sender quits, receiver seeks through it), and the same with a real Cloudflare node on Vitalik's test account.
- **Health checks:** a harness blobd that deletes recent blobs is flagged after two checks and cleared after four clean ones; a full blobd evicting its oldest blobs is never flagged; a forged `/status` signature flags at once.
- **Billing check:** a scripted abuse run against a test Cloudflare node (request flood, write flood, junk fill), then the account's billable usage page read back showing zero.
- **Feature matrix:** rows for personal node, server pool, Cloudflare node, blobd, retreat and hand-off, the per-conversation dialog.

---

## 15. Decisions (Vitalik, 2026-09-17)

1. **Using nodes:** allowed by default, with a dialog before the first connection in each DM or server offering to turn nodes off there (section 11).
2. **Extra copies:** 0 to 5, default 0 for full capacity; the Storage page shows the capacity cost (6.2).
3. **Cloudflare quota:** 9.5 GB default; "are you sure" between 9.5 and 10 GB; a cost estimate above 10 GB (7.2).
4. **Adding a node:** any member, no approval, like a boost; a public dashboard keeps it honest, with pool health checks against deleting or black-hole nodes (6.1, 6.7).
5. **Signing:** extended. v4 binds the blob through a digest of all optional fields, ending per-field versions (4.2).
6. **Share:** nodes replace it up to a size limit of 100 MB by default, 500 MB at most, set by owners and admins; bigger files still use Share (6.5).
7. **File types:** all kinds, with owner and admin block lists (6.5).
8. **The token** stays on the volunteer's device for updates and retreat, revocable; the pool never sees it. Retreat hands files to accepting nodes (6.6, 8.2).

Still open, to settle during the build:

- **Rate limiting binding on the Free plan.** Cloudflare's per-key request counter for Workers is not documented for the Free plan. Not needed (the Durable Object counts per pass); the first real deploy on Vitalik's account shows whether it deploys, and if it does it becomes a cheap first filter for writes.

Decided in the follow-up the same day:

9. **Pool health** runs on the existing 30-minute timer by one elected checker per server, telling eviction from deletion by each node's oldest retained upload, and flags deleting nodes loudly at the top of the dashboard at the lowest priority until they are clean again (6.7).
10. **Priority** is proportional to donated space, times health, times free-tier headroom for nodes that stay free (6.2).
11. **Costs** use the documented R2 prices (no price API), counted per node and for the pool on the dashboard, storage and both operation classes (7.4).
12. **New nodes** take half weight for 24 hours; two failed checks flag, four clean checks clear (6.2, 6.7).

## 16. File touch list

**New**
- `storage-worker/` (Worker source, Durable Object, tests, build script), `assets/storage_worker/worker.js` (built, versioned).
- `rust/hollow_blobd/` (the service), `relay-uws/docker-compose.yml` profile `storage`, `relay-uws/SELF_HOSTING.md` section, a NAS guide in the help center.
- `rust/hollow_core/src/node/storage_nodes.rs` (registry, passes, placement, repair), `rust/hollow_core/src/node/blob.rs` (format, chunk crypto, index, verification), `rust/hollow_core/src/node/hbp_client.rs` (HTTP client, range fetch, uploads, multipart), `rust/hollow_core/src/node/cloudflare_setup.rs` (API calls for setup, update, removal), `rust/hollow_core/src/api/storage_nodes.rs` (FFI).
- `lib/src/ui/settings/storage_nodes_page.dart`, `lib/src/ui/dialogs/donate_storage_flow.dart`, mobile twins.

**Changed**
- `node/types.rs`: `BlobRef` (boxed) on `FileHeaderPayload`, `SyncFileMetaItem`, public file metadata; new envelopes `StoragePassRequest`, `StoragePassGrant`, `StorageRegistryAnnounce`, `StorageRegistryRequest`, `StorageRegistryResponse`.
- `node/file_handler.rs`: blob upload after send, skip vault-only when the pool is healthy, header carries `blob`.
- `node/file_asks.rs`: nodes as a source ahead of peers when enabled; unavailability states.
- `node/at_rest.rs` and the video loopback (`atRestMediaUrl`): range reads backed by blob chunks.
- `storage/messages.rs`: `files.blob_json`, a `storage_nodes` table, a `storage_passes` table.
- `lib/src/ui/chat/file_card_status.dart`: the two node captions.
- `lib/src/core/providers/file_transfer_provider.dart`: background placement instead of the vault upload when the pool is healthy.
- Settings > Privacy: the global node default; per-conversation settings: the node choice; the first-connection dialog.
- `node/crypto_handler.rs`: `hollow-msg4` with the extras digest; `SignedExtras` gains `blob_id` and `blob_size`.
- Server settings: extra copies (0 to 5), node file size limit (100 to 500 MB), blocked file types.
- Wiki `security_write_gates.md`: rows for registry ingest, pass grants, blob ingest.
- `WHITEPAPER.md`: a storage nodes section (format, passes, what nodes learn).
- `HOLLOW_PLAN.md`: rewrite the volunteer storage pool bullet to point here.
