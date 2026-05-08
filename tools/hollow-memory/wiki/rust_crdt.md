# CRDT System — Collaborative Server State

Hollow servers have no central authority. Every member holds a full copy of the server state (name, channels, members, roles, labels, bans, permissions, settings). Mutations are expressed as operation-based CRDTs: each change is a self-contained `CrdtOp` that is commutative (order-independent) and idempotent (safe to apply multiple times). All peers converge to the same state regardless of the order they receive operations.

Source: `rust/hollow_core/src/crdt/` — modules: `operations.rs`, `hlc.rs`, `admin_lww.rs`, `server_state.rs`, `sync.rs`. There is no separate `store.rs`; persistence and compaction are handled inline in `server_state.rs:apply_op()`.

---

## HLC — Hybrid Logical Clock (`hlc.rs`)

Provides globally unique, monotonically increasing timestamps for total ordering of CRDT operations across all peers, even when wall clocks disagree.

### HlcTimestamp Structure

```
HlcTimestamp {
    physical_ms: u64,   // milliseconds since UNIX epoch
    counter: u32,       // logical counter for same-ms disambiguation
    actor: String,      // peer_id of the timestamp creator
}
```

**Total ordering** is `physical_ms` then `counter` then `actor` (lexicographic string comparison on peer_id). This guarantees no two timestamps are ever equal — even if two peers generate timestamps at the exact same millisecond with the same counter, the actor string breaks the tie deterministically.

`hlc.rs:HlcTimestamp::zero()` creates a timestamp with `physical_ms=0, counter=0` for a given actor — used as an initial sentinel.

### Hlc Clock

```
Hlc {
    latest: HlcTimestamp,  // highest timestamp seen or generated
    actor: String,         // this node's peer_id
}
```

**`hlc.rs:Hlc::new()`** — Creates a clock seeded with the current wall clock time and counter 0.

**`hlc.rs:Hlc::from_saved()`** — Restores from persisted state (physical_ms, counter, actor). Used after loading ServerState from SQLCipher.

**`hlc.rs:Hlc::now()`** — Generates a new timestamp guaranteed greater than all previously generated or witnessed timestamps:
- If wall clock > `latest.physical_ms`: reset counter to 0, use wall clock.
- Else: increment `latest.counter` by 1 (logical tick within same physical time).
- Always stamps the local `actor` on the result.

**`hlc.rs:Hlc::witness()`** — Merges a remote timestamp into the local clock so the next `now()` is strictly greater than both clocks. Called inside `server_state.rs:apply_op()` for every incoming remote operation. Algorithm:
1. Compute `max_physical` = max(wall, self.physical_ms, other.physical_ms).
2. If all three physical times are equal: counter = max(self.counter, other.counter) + 1.
3. If self is highest: counter += 1.
4. If other is highest: adopt other's physical_ms, counter = other.counter + 1.
5. If wall is highest: adopt wall, counter = 0.
6. Always stamps local actor.

**SECURITY — Drift rejection (5-minute window):** If `other.physical_ms` is more than 5 minutes ahead of the local wall clock, the witness is silently rejected. This prevents a malicious peer from advancing the local HLC to the far future, which would give their LWW values permanent precedence. Logged via `hollow_log!` with `[HOLLOW-SECURITY]` prefix.

**Persistence accessors:** `hlc.rs:Hlc::physical_ms()`, `hlc.rs:Hlc::counter()`, `hlc.rs:Hlc::actor()` — read-only for serialization to SQLCipher.

---

## AdminLwwReg — Role-Priority Last-Write-Wins Register (`admin_lww.rs`)

A conflict-resolution register where **higher-ranked users always win**, regardless of timestamp. This prevents a Member from overriding an Admin's change even if the Member's timestamp is later.

### Structure

```
AdminLwwReg<V: Clone> {
    value: V,           // the stored value (generic: String, MemberRole, u32, u64, bool)
    priority: u8,       // author's role priority at write time
    hlc: HlcTimestamp,  // when the write occurred
}
```

### Conflict Resolution — `admin_lww.rs:AdminLwwReg::merge()`

Two-tier comparison:
1. **Higher priority wins unconditionally.** If `other.priority > self.priority`, adopt other's value, priority, and HLC. A Member (priority 0) can never override an Admin (priority 2), even with a later timestamp.
2. **Equal priority falls back to HLC ordering.** If priorities match and `other.hlc > self.hlc`, adopt other. Standard last-writer-wins within the same authority tier.
3. **Lower priority is silently ignored.** If `other.priority < self.priority`, no change.

### Priority Values (from `operations.rs:MemberRole::priority()`)

| Role      | Priority |
|-----------|----------|
| Owner     | 3        |
| Admin     | 2        |
| Moderator | 1        |
| Member    | 0        |

### API

- `admin_lww.rs:AdminLwwReg::new(value, hlc, priority)` — constructor.
- `admin_lww.rs:AdminLwwReg::update(value, hlc, priority)` — local unconditional write (no conflict check). Used before broadcasting.
- `admin_lww.rs:AdminLwwReg::read()` — returns `&V`.
- `admin_lww.rs:AdminLwwReg::priority()` — returns current priority.
- `admin_lww.rs:AdminLwwReg::hlc()` — returns current timestamp.
- `admin_lww.rs:AdminLwwReg::merge(&other)` — conflict resolution as above.

### Where AdminLwwReg Is Used in ServerState

- `ServerState.name` — `AdminLwwReg<String>` (server name)
- `ServerState.roles` — `HashMap<String, AdminLwwReg<MemberRole>>` (peer_id to role)
- `ServerState.nicknames` — `HashMap<String, AdminLwwReg<String>>` (peer_id to nickname)
- `ServerState.twitch_usernames` — `HashMap<String, AdminLwwReg<String>>`
- `ServerState.storage_pledges` — `HashMap<String, AdminLwwReg<u64>>` (peer_id to bytes pledged)
- `ServerState.settings` — `HashMap<String, AdminLwwReg<String>>` (key-value server settings)
- `ServerState.role_permissions` — `HashMap<String, AdminLwwReg<u32>>` (role name to permission bitmask)
- `ServerState.banned_members` — `HashMap<String, AdminLwwReg<bool>>` (peer_id to banned flag)

---

## CrdtPayload and CrdtOp — Operations (`operations.rs`)

### CrdtOp Wrapper

```
CrdtOp {
    server_id: String,       // which server this op belongs to
    hlc: HlcTimestamp,       // when the op was created
    author: String,          // peer_id of the originator
    payload: CrdtPayload,   // the actual mutation
}
```

Self-contained: every op carries its own server, author, timestamp, and payload. No external context needed to apply it.

### CrdtPayload Variants

**Server-level:**
- `ServerCreated { name: String, owner_peer_id: String }` — genesis operation. Sets server name as AdminLwwReg with Owner priority. Adds owner to members and roles.
- `ServerRenamed { new_name: String }` — changes server name via AdminLwwReg merge. Author priority looked up from their role in the server.
- `ServerSettingChanged { key: String, value: String }` — generic key-value settings (e.g., `min_pledge_mb`). Each key is an AdminLwwReg<String>.

**Channel operations:**
- `ChannelAdded { channel_id: String, name: String, category: Option<String>, channel_type: String }` — adds a channel. `channel_type` is `"text"` or `"voice"` (defaults to text). Uses `or_insert_with` — first writer wins for the same channel_id, subsequent adds are no-ops.
- `ChannelRemoved { channel_id: String }` — removes channel from the HashMap. Straightforward delete.
- `ChannelRenamed { channel_id: String, new_name: String }` — updates channel name in place. No LWW — last applied wins.
- `ChannelVisibilityChanged { channel_id: String, visibility: String }` — sets who can see the channel. Values: `"everyone"`, `"moderator"`, `"admin"`.
- `ChannelPostingChanged { channel_id: String, posting: String }` — sets who can post. Same value set.
- `ChannelLayoutUpdated { layout_json: String }` — replaces the entire channel layout ordering. The JSON string is deserialized to `Vec<ChannelLayoutItem>`. Last applied wins (no LWW merge, just overwrite).

**Member operations:**
- `MemberAdded { peer_id: String, display_name: String }` — adds member with default Member role. Uses `or_insert_with` — idempotent, won't overwrite existing member.
- `MemberRemoved { peer_id: String }` — removes member from `members`, `roles`, `nicknames`, `twitch_usernames`, and `storage_pledges`. Full cleanup.
- `MemberBanned { peer_id: String }` — sets `banned_members[peer_id] = true` via AdminLwwReg merge, then removes the peer from all member maps (same cleanup as MemberRemoved). Ban = kick + prevent rejoin.
- `MemberUnbanned { peer_id: String }` — sets `banned_members[peer_id] = false` via AdminLwwReg merge. Does NOT re-add the member; they must rejoin.

**Role operations:**
- `RoleChanged { peer_id: String, role: MemberRole, priority: u8 }` — changes a member's power role. The `priority` field is the **author's** role priority (not the target role's priority). This ensures higher-ranked authors can demote lower-ranked members. Applied via AdminLwwReg merge.
- `RolePermissionsChanged { role: String, permissions: u32 }` — overrides the default permission bitmask for a role. Stored in `role_permissions` as AdminLwwReg<u32>.

**Nickname / identity:**
- `NicknameChanged { peer_id: String, nickname: String }` — sets a member's server nickname. AdminLwwReg merge with author's priority. Members can set their own; admins can change others'.
- `TwitchUsernameChanged { peer_id: String, twitch_username: String }` — stores Twitch username verified via OAuth. Same AdminLwwReg pattern.

**Pin operations:**
- `MessagePinned { channel_id: String, message_id: String }` — appends to the pin list for a channel if not already present.
- `MessageUnpinned { channel_id: String, message_id: String }` — removes from the pin list. Cleans up the channel entry if the list becomes empty.

**Storage (Phase 4 vault):**
- `StoragePledgeChanged { peer_id: String, pledge_bytes: u64 }` — sets how much disk space a member pledges for vault shards. AdminLwwReg merge.

**Labels (Phase 6.75 cosmetic roles):**
- `LabelCreated { label_id: String, name: String, color: String }` — creates a cosmetic label. Uses `or_insert_with` — first creator wins for the same label_id.
- `LabelDeleted { label_id: String }` — removes the label from `labels` and strips it from all members' `label_assignments`.
- `LabelUpdated { label_id: String, name: String, color: String }` — updates name and color of an existing label. No LWW — last applied wins.
- `LabelAssigned { label_id: String, peer_id: String }` — adds label to a member's assignment list if not already present.
- `LabelUnassigned { label_id: String, peer_id: String }` — removes label from a member's assignment list. Cleans up empty entries.

### MemberRole Enum

```
Owner     — priority 3
Admin     — priority 2
Moderator — priority 1
Member    — priority 0
```

**`operations.rs:MemberRole::priority()`** — returns the `u8` priority value.
**`operations.rs:MemberRole::as_str()`** — returns `"owner"`, `"admin"`, `"moderator"`, `"member"`.
**`operations.rs:MemberRole::from_str()`** — parses string to role; defaults to Member for unrecognized input.
**`operations.rs:MemberRole::default_permissions()`** — returns the default bitmask for this role.
**`operations.rs:MemberRole::outranks()`** — returns `self.priority() > other.priority()`.

### Permission Bitmask Constants

```
Permission::MANAGE_SERVER   = 1 << 0  (bit 0)
Permission::MANAGE_CHANNELS = 1 << 1  (bit 1)
Permission::MANAGE_ROLES    = 1 << 2  (bit 2)
// bit 3 is unused (MANAGE_INVITES was removed)
Permission::KICK_MEMBERS    = 1 << 4  (bit 4)
Permission::SEND_MESSAGES   = 1 << 5  (bit 5)
Permission::READ_MESSAGES   = 1 << 6  (bit 6)
Permission::ALL = all of the above OR'd together
```

**Default permissions by role:**
- Owner: ALL
- Admin: MANAGE_CHANNELS | MANAGE_ROLES | KICK_MEMBERS | SEND_MESSAGES | READ_MESSAGES
- Moderator: KICK_MEMBERS | SEND_MESSAGES | READ_MESSAGES
- Member: SEND_MESSAGES | READ_MESSAGES

---

## ServerState — Full CRDT State (`server_state.rs`)

The complete replicated state of a Hollow server. Every field is either an add-wins set (HashMap with `or_insert_with`), an AdminLwwReg, or a simple overwrite.

### All Fields

| Field | Type | CRDT Strategy | Serde |
|-------|------|---------------|-------|
| `server_id` | `String` | Immutable identifier | Required |
| `name` | `AdminLwwReg<String>` | LWW with role priority | Required |
| `channels` | `HashMap<String, ChannelInfo>` | Add-wins (first insert sticks), remove deletes | Required |
| `members` | `HashMap<String, MemberInfo>` | Add-wins, remove deletes | Required |
| `roles` | `HashMap<String, AdminLwwReg<MemberRole>>` | LWW per member | Required |
| `nicknames` | `HashMap<String, AdminLwwReg<String>>` | LWW per member | `#[serde(default)]` |
| `twitch_usernames` | `HashMap<String, AdminLwwReg<String>>` | LWW per member | `#[serde(default)]` |
| `pinned_messages` | `HashMap<String, Vec<String>>` | Add/remove set per channel | `#[serde(default)]` |
| `channel_layout` | `Vec<ChannelLayoutItem>` | Last-write overwrite | `#[serde(default)]` |
| `storage_pledges` | `HashMap<String, AdminLwwReg<u64>>` | LWW per member | `#[serde(default)]` |
| `settings` | `HashMap<String, AdminLwwReg<String>>` | LWW per key | Required |
| `role_permissions` | `HashMap<String, AdminLwwReg<u32>>` | LWW per role name | `#[serde(default)]` |
| `banned_members` | `HashMap<String, AdminLwwReg<bool>>` | LWW per peer_id | `#[serde(default)]` |
| `labels` | `HashMap<String, LabelInfo>` | Add-wins, remove deletes | `#[serde(default)]` |
| `label_assignments` | `HashMap<String, Vec<String>>` | Add/remove set per peer | `#[serde(default)]` |
| `op_log` | `Vec<CrdtOp>` | Append-only (compacted at 1000) | Required |
| `hlc` | `Option<Hlc>` | Transient (not serialized) | `#[serde(skip)]` |

### Data Structures

**`ChannelType`** — enum: `Text` (default), `Voice`. Serde-renamed to lowercase strings.

**`ChannelLayoutItem`** — tagged enum for channel sidebar ordering:
- `Category { name: String }` — section header
- `Channel { channel_id: String }` — reference to a channel
- `Separator` — visual divider

**`ChannelVisibility`** — enum: `Everyone` (default), `ModeratorPlus`, `AdminPlus`. Controls who can see a channel.

**`ChannelPosting`** — enum: `Everyone` (default), `ModeratorPlus`, `AdminPlus`. Controls who can post.

**`ChannelInfo`** — per-channel metadata:
- `channel_id: String`, `name: String`, `category: Option<String>`
- `channel_type: ChannelType` (`#[serde(default)]`)
- `visibility: ChannelVisibility` (`#[serde(default)]`)
- `posting: ChannelPosting` (`#[serde(default)]`)

**`MemberInfo`** — `{ peer_id: String, display_name: String }`.

**`LabelInfo`** — `{ label_id: String, name: String, color: String }`. Cosmetic tag/badge.

### Construction

**`server_state.rs:ServerState::new(server_id, name, creator_peer_id)`** — creates a server with:
- A `#general` channel (ID = first 8 chars of server_id + `-general`).
- Creator as sole member.
- Creator role set to Owner.
- HLC initialized with creator's peer_id.
- All other maps empty, op_log empty.

**`server_state.rs:ServerState::set_hlc()`** — restores the HLC after deserialization (HLC is `#[serde(skip)]`). Must be called after loading from SQLCipher before creating new ops.

### Operation Creation

**`server_state.rs:ServerState::create_op(payload)`** — generates a CrdtOp with:
- `server_id` from self.
- `hlc` from `self.hlc.now()` (advances the clock).
- `author` from `self.hlc.actor()`.
- The provided payload.

Does NOT apply the op — caller must call `apply_op()` separately after broadcasting. This ensures the op is sent to peers before local application, maintaining causal ordering.

### Operation Application — `server_state.rs:ServerState::apply_op()`

The core convergence function. Every mutation to ServerState goes through this single entry point.

**Prechecks:**
1. Validates `op.server_id` matches `self.server_id`. Returns `Err` on mismatch.
2. Duplicate detection: scans `op_log` for any existing op with same `author` AND same `hlc`. If found, returns `Ok(())` silently (idempotent).
3. Calls `hlc.witness(&op.hlc)` to advance local clock past the remote timestamp.

**Payload dispatch** — match on `op.payload` and apply the mutation (see CrdtPayload Variants above for each variant's behavior).

**Op log management** (after every successful apply):
- Binary-search insert into `op_log` by HLC for deterministic ordering.
- **Compaction:** if `op_log.len() > 1000`, drain oldest ops (`op_log.drain(..excess)`). This bounds memory. Older ops are already materialized into the state fields and don't need to be retained. The 1000-op window is sufficient for the sync protocol's delta computation.

### Author Priority Lookup

**`server_state.rs:ServerState::author_priority()`** — looks up the author's current role in `self.roles` and returns its priority (0-3). Returns 0 (Member) if unknown. Used by AdminLwwReg-based fields (nicknames, settings, storage pledges, role_permissions, banned_members, twitch_usernames) to determine the priority for the merge.

### Permission System

**`server_state.rs:ServerState::get_permissions(peer_id)`** — returns the effective u32 bitmask:
1. If role is Owner: return `Permission::ALL` unconditionally.
2. Check `role_permissions` for a custom override for this role string.
3. Fall back to `MemberRole::default_permissions()`.

**`server_state.rs:ServerState::get_role_permissions(role_str)`** — same logic but takes a role string instead of peer_id. Used for the permission editor UI.

**`server_state.rs:ServerState::has_permission(peer_id, permission)`** — bitwise AND check on `get_permissions()`.

### Role Change Authorization

**`server_state.rs:ServerState::can_change_role(actor, target, new_role)`** — enforces hierarchy:
1. Owner can do anything.
2. Actor must have `MANAGE_ROLES` permission.
3. Actor must outrank the target's current role.
4. Actor must outrank the new_role being assigned.
5. Cannot set anyone to Owner via role change (ownership transfer not supported this way).

### Kick / Ban Authorization

**`server_state.rs:ServerState::can_kick(actor, target)`** — Owner can kick anyone. Otherwise requires `KICK_MEMBERS` permission AND actor must outrank target.

**`server_state.rs:ServerState::can_ban(actor, target)`** — delegates to `can_kick()` (same hierarchy rules).

**`server_state.rs:ServerState::is_banned(peer_id)`** — reads the AdminLwwReg<bool> for the peer. Returns false if not in the map.

**`server_state.rs:ServerState::banned_list()`** — collects all peer_ids where `banned_members[pid]` reads `true`.

### Channel Access Control

**`server_state.rs:ServerState::can_see_channel(peer_id, channel_id)`** — Owner sees everything. Otherwise checks `ChannelVisibility`:
- `Everyone`: always visible.
- `ModeratorPlus`: requires role priority >= Moderator (1).
- `AdminPlus`: requires role priority >= Admin (2).

**`server_state.rs:ServerState::can_post_in_channel(peer_id, channel_id)`** — Owner can post anywhere. Otherwise checks `ChannelPosting`:
- `Everyone`: requires `SEND_MESSAGES` permission.
- `ModeratorPlus`: requires role priority >= Moderator.
- `AdminPlus`: requires role priority >= Admin.

**Important:** Channel visibility/posting is UI-filtered only. All members still receive all messages via the server-wide MLS group. True enforcement requires per-channel MLS subgroups (not yet implemented).

### Query Helpers

- `server_state.rs:ServerState::channels_list()` — returns `Vec<&ChannelInfo>` sorted by name.
- `server_state.rs:ServerState::members_list()` — returns `Vec<&MemberInfo>` sorted by display_name.
- `server_state.rs:ServerState::get_role(peer_id)` — returns `MemberRole` (defaults to Member).
- `server_state.rs:ServerState::name()` — returns `&str` from the AdminLwwReg.
- `server_state.rs:ServerState::get_nickname(peer_id)` — returns String (empty if no nickname).
- `server_state.rs:ServerState::get_twitch_username(peer_id)` — returns String (empty if not set).
- `server_state.rs:ServerState::get_pinned_messages(channel_id)` — returns `Vec<String>` of message IDs.
- `server_state.rs:ServerState::get_storage_pledge(peer_id)` — returns u64 bytes (0 if not set).
- `server_state.rs:ServerState::total_pledged_bytes()` — sum of all storage pledges.
- `server_state.rs:ServerState::min_pledge_mb()` — reads `settings["min_pledge_mb"]`, defaults to 512.
- `server_state.rs:ServerState::labels_list()` — returns `Vec<&LabelInfo>` sorted by name (stable ordering for UI).
- `server_state.rs:ServerState::get_member_labels(peer_id)` — resolves label_ids to LabelInfo references.

### Utility

**`server_state.rs:short_name(peer_id)`** — truncates peer_id to 12 chars + `...` for display_name on member creation.

---

## State Vector Sync Protocol (`sync.rs`)

Efficient delta-based synchronization between peers. Instead of exchanging full state, peers exchange compact state vectors and then only send the operations the other side is missing.

### StateVector

```
StateVector {
    server_id: String,
    entries: HashMap<String, HlcTimestamp>,  // actor → latest HLC seen from that actor
}
```

**`sync.rs:StateVector::from_op_log(server_id, ops)`** — scans an op slice and records the highest HLC per author. O(n) in op_log size.

**`sync.rs:StateVector::from_server_state(state)`** — convenience wrapper that calls `from_op_log()` with the state's op_log.

### Sync Flow

The protocol is symmetric — either peer can initiate:

1. **Peer B sends its StateVector to Peer A.**
2. **Peer A calls `sync.rs:compute_delta(our_ops, their_vector)`** — returns `Vec<&CrdtOp>` (zero-copy references) of ops that B is missing. An op is "missing" if:
   - The op's author doesn't appear in B's state vector at all, OR
   - The op's HLC is strictly greater than B's latest for that author.
3. **Peer A serializes the delta refs directly** (serde handles `&CrdtOp` identically to `CrdtOp`) and sends to Peer B.
4. **Peer B calls `sync.rs:merge_ops(state, incoming_ops)`** — applies each op via `state.apply_op()`. Duplicates are automatically skipped (idempotent). Returns the count of newly applied ops.
5. **Repeat in reverse direction** (B sends delta to A) for full bidirectional sync.

### merge_ops Details

**`sync.rs:merge_ops(state, incoming_ops)`** — iterates through incoming ops, calls `apply_op()` for each, and counts how many actually increased the op_log length (i.e., were new, not duplicates). Returns `Result<usize, String>`.

### Op Log Size and Sync Window

The op_log is compacted to 1000 entries in `apply_op()`. This means the sync protocol can only compute deltas for the most recent 1000 operations per server. For servers that have been running longer, a full state snapshot exchange would be needed (not currently implemented as a separate mechanism — new members receive the full ServerState during initial sync via `sync_handler.rs`).

---

## Op Log Persistence and Compaction

There is no separate `store.rs` module. Op persistence and compaction are handled inline within `server_state.rs:apply_op()`:

**Storage:** The `op_log: Vec<CrdtOp>` is a field on ServerState. The entire ServerState (including op_log) is serialized as JSON and stored in SQLCipher. The HLC field is `#[serde(skip)]` and must be restored via `set_hlc()` after deserialization.

**In-memory compaction:** `MAX_OP_LOG = 1000`. After every successful apply, if the op_log exceeds 1000 entries, the oldest entries are drained: `op_log.drain(..excess)`. This prevents unbounded memory growth.

**DB-level pruning:** The `crdt_ops` SQLCipher table is pruned every 30 minutes via `CrdtStore::prune_ops(1000)` (called from the rebalance_timer). Uses `ROW_NUMBER() OVER (PARTITION BY server_id ORDER BY hlc_ms DESC)` to keep only the latest 1000 per server.

**Transaction batching:** The CrdtStore actor wraps each drain cycle (all process_cmd calls + pending state/blob flushes) in a single SQLite transaction (`BEGIN IMMEDIATE`/`COMMIT`), coalescing N fsyncs into 1.

**Insertion order:** Ops are binary-search inserted by HLC into the op_log, maintaining deterministic sorted order. This is critical for `StateVector::from_op_log()` which scans for the latest HLC per author, and for `compute_delta()` which filters by HLC comparison.

**Duplicate detection:** Before applying, `apply_op()` does a linear scan of `op_log` checking `author == op.author && hlc == op.hlc`. Same author + same HLC = same op (since a single HLC can only be generated once by a given actor). Duplicates return `Ok(())` with no state change.

---

## Convergence Guarantees

The CRDT system guarantees eventual consistency through these properties:

1. **Commutativity:** Operations can be applied in any order and produce the same final state. Tested in `server_state.rs::tests::concurrent_ops_converge` — two peers applying the same ops in opposite order reach identical state.

2. **Idempotency:** Applying the same operation multiple times has no additional effect. The duplicate detection in `apply_op()` ensures op_log doesn't grow, and `or_insert_with` semantics prevent overwriting existing entries.

3. **Convergence of LWW fields:** AdminLwwReg's two-tier merge (priority then HLC) is commutative — `a.merge(b)` and `b.merge(a)` produce the same winner. Tested in `admin_lww.rs::tests`.

4. **Add-wins semantics for sets:** Channels, members, and labels use `or_insert_with` — concurrent adds of the same ID don't conflict. Removes are explicit deletes. The add-wins property means a concurrent add and remove might resurrect the entry, which is acceptable for the use case (the member/channel can be removed again).

5. **Total ordering via HLC:** Every operation has a globally unique, totally ordered timestamp. No two operations can have the same HLC (the actor field breaks ties). This makes the op_log deterministically ordered across all peers.

---

## Integration Points

**Dart side:** `server_state_provider.dart` holds `ServerState` objects per server. CRDT ops are created via FFI calls to `create_op()`, broadcast to peers via the MLS-encrypted channel, and applied locally. Incoming ops from peers go through `apply_op()` via `sync_handler.rs:handle_envelope_crdt_op()`.

**Sync trigger:** When a peer joins a WS room, `sync_handler.rs` exchanges StateVectors and applies deltas. This is the primary convergence mechanism.

**Event emission:** New CrdtPayload variants that affect permissions, channels, labels, or bans MUST emit `NetworkEvent::ServerUpdated` in both `handle_envelope_crdt_op()` (sync_handler.rs) and `handle_incoming_request()` (swarm.rs). Falling into the `_ =>` wildcard emits `SyncCompleted` instead, which does NOT trigger provider invalidation on the Dart side.

**Backward compatibility:** All newer HashMap fields on ServerState use `#[serde(default)]` so that old serialized data (which lacks these fields) deserializes without error. Omitting `#[serde(default)]` on a new field will cause deserialization failure and data loss (servers vanish from the UI).
