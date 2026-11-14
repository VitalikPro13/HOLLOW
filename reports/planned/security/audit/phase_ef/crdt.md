# Phase E slice "crdt": server state, the design E fold, checkpoint coverage, the device proof

Pre-freeze STRIDE pass for 0.14 (2026-11-05), the slice the 0.13 review left open (flow F-30;
`coverage.md` WP3 "Not examined"). Code read on `security/0.14` at `56587ca2` (worktree
`~/dev/wt/t14-docs`). Nothing was built or run: verdicts come from reading the code, the
designs and the wiki gate rows, and every test named exists in that tree unless it is marked
*planned*. The device proof (`DEVICE_PROOF_DESIGN.md` rev 3.5, in `~/dev/wt/t14-checkpoint`)
is walked as designed, since track C has not built its CRDT half.

## Scope

- Elements (all in E-02, the Rust core):
  - P1 the door and the fold: `crdt/fold.rs` (`ServerState::ingest_remote`, `fold_remote`,
    `stateless_check`, `plan`, `base_of`, `allocate`, `join_answer`, `accept_join_snapshot`,
    `author_checked`, the writer rule `checkpoint_witnessed`, `checkpoint_fits`,
    `author_due_checkpoint`, `refused_own_admission`), `crdt/dominance.rs`,
    `crdt/members.rs`, `crdt/voids.rs`.
  - P2 the authority predicate: `crdt/server_state.rs` (`op_allowed`, `admission_allowed`,
    `checkpoint_allowed`, `found`, `restore_op_log`, `clamp_future_hlcs`), `crdt/anchor.rs`.
  - P3 the op format and parsing: `crdt/operations.rs` (`CrdtOp::verify_author`, `read_op`,
    `parse_ops_tolerant`).
  - P4 the transports into P1: the MLS arm `node/sync_handler.rs::handle_envelope_crdt_op`,
    the carried Olm twin `node/swarm.rs::apply_remote_crdt_op` (`CrdtOpBroadcast`, kick
    notices, join resolution), the `SyncResponse` arm, digest catch-up (`crdt/digest.rs`,
    `node/op_sync.rs`, `node/crdt_resync.rs::answer_digest`) and whole-log pages
    (`crdt_resync::page`, `ingest_page`).
  - DS1 the op store: `crdt_ops` rows written by `MessageStore::persist_op_delta` through
    `CrdtStore::persist`, restored by `restore_op_log`; the kept unread ops
    (`server_blobs` key `crdt_resync_kept`).
  - DS2 in-RAM state: the materialized `ServerState`, `held`, the `Quota`, the RAM-only
    `cp_retry_at_ms`.
- Flows: F-30 (ops over MLS, the Olm twin, sync and digest answers), F-31 (the join answer
  and, for 32-hex servers only, the join snapshot), the owner checkpoint.
- External interactors: X-2 relay, X-3 peers (members at every role, the owner, a joiner,
  a stranger holding the server id), X-4 own sibling devices, and P-08 (a removed device).
- Leads: HOL-SEC-188 (open), AR-10, AR-11, AR-12.

## Summary

- STRIDE cells walked: 48 (4 processes x 6, 2 stores x 3, 3 flows x 3, 3 interactors x 2,
  minus the cells that do not apply to a store, counted once).
- Open, already numbered: HOL-SEC-188 (a removed device keeps authoring with the master
  key) until track C lands. Every other threat below has a gate in the tree and a test.
- New candidates: none above Info. Two record gaps (G-C1, G-C2) and one stale register row
  (G-C3) for the lead; see the end.
- Release-relevant: AR-12 is closed by checkpoint coverage (56587ca2) but the register still
  says Accepted (G-C3).

## Assets

| Asset | Why it matters here |
|---|---|
| AS-07 server state | Membership, roles, bans, mutes, channels and their access, the public flag, the join lock, ownership. Whoever writes it decides who reads a server. |
| The anchor | The founding op of a 40-hex id, or the owner's checkpoint (with the `owner=` pin). A forged anchor is a server takeover for every joiner. |
| Convergence | Two replicas holding the same ops and rosters must agree on state, retained set and digest. A split is a lasting fork nobody sees. |
| AS-11 availability | A backdated or junk flood costs every member a rebuild and storage; a wedged sync stops a server for an old build. |

## Trust boundaries

- TB-2: every op author is another principal; a signature names the author, never its
  right to act (design E principle 3).
- TB-1: the relay carries MLS frames and the sealed Olm twin; it can drop, delay, reorder
  and replay, never read or forge.
- TB-3: a sibling device is the same identity; a removed device (P-08) still holds the
  master key, which is the HOL-SEC-188 boundary.

## STRIDE

### P1 + P2: the door, the fold and the authority predicate

| Class | Threat | Mitigation (code) | Residual | Test |
|---|---|---|---|---|
| S | A peer signs an op naming another author. | `CrdtOp::verify_author` over the master-signed bytes; unsigned refused; author read by its own id, never the resolver (`op_allowed` -> `author_role`). | none | `ingest_rejects_unsigned_op`, `op_allowed_ingest_matrix` |
| S | A device its roster removed signs with the master key (owner checkpoint, `ServerDeleted`, kicks). | Planned: `CrdtOp.dev` device proof, verdict under `Roster::authority()`, the cut (DEVICE_PROOF section 3). Committed so far: the join lock half (5af8f7b7) and `authority()` (060ca581). | **OPEN, HOL-SEC-188** until track C | *planned* `after_the_cut_an_uncounted_op_folds_only_if_dominated` |
| S | A stranger founds a server under a known id, or a member hands a joiner a forged founding op. | 40-hex id = hash of owner and nonce (`crdt/anchor.rs`, `ServerState::found`); a founding op lands only on an ownerless state from the key that hashes to the id. | 32-hex legacy servers: AR-10 | `derived_ids_have_the_genesis_shape_and_bind_owner_and_nonce` |
| S | Anyone but the anchor owner signs a checkpoint, or a checkpoint names another owner. | `checkpoint_allowed`; `base_of` takes only a well-formed checkpoint of the anchor owner whose parent is held and whose generation is the parent's plus one. | none | `a_checkpoint_with_a_wrong_generation_or_a_missing_parent_is_no_base` |
| T | The relay or a member reorders, replays or withholds ops to pick each replica's outcome. | State = fold of every retained op in HLC order, each judged at its point (`plan`); duplicates dedup by (author, clock, content hash). | Withholding by an asked responder: wiki section 40 residual L2 (no AR row, G-C1) | `rival_owner_checkpoints_converge_without_loss` |
| T | Two different ops at one (author, clock) split replicas. | Lowest SHA-256 of the signed bytes wins at the door, in `plan`, in `digest::id_hash` and in the store upsert. | none | `equivocation_keeps_the_lowest_hash_everywhere` |
| T | A checkpoint wipes ops its owner never folded (late leave, rejoin, admission). | Checkpoint coverage: per-element stamps; an op the base does not dominate folds on top (`crdt::dominance::Judge::dominates`, one exhaustive match per payload); dormant rows keep a rival checkpoint lossless. | Design section 16 (a stamp missed on one element; forks two generations deep) | `probe_concurrent_owner_checkpoints_lose_an_op_today` (now asserts no loss), `digest_entries_agree_across_bases_and_include_the_dormant_set` |
| T | A member lists someone who never asked, or an old ask readmits a leaver. | `admission_allowed`: the target's own `JoinAsk` for this server, newer than every ask that opened a span and than its own last leave (`crdt::members::derive`). | none | `authz_member_added_names_only_someone_who_asked`, `probe_an_ask_older_than_the_askers_own_leave_readmits_it` |
| R | An author denies an op, or a device of an identity denies being the one that wrote it. | Every op is master-signed; device attribution comes with the track C proof. | Until track C, an op names an identity, not a device (part of HOL-SEC-188) | as above |
| I | The fold or an answer reveals state to a non-member. | Digest and page answers serve members only; a non-member gets only its own removal notice (`crdt/sync.rs::removal_notice`, `crdt_resync::answer_digest`). | Every member holds the whole state, restricted channels' names and settings included (G-C2) | `g13_non_member_digest_gets_only_the_removal_notice` |
| D | A flood of backdated or junk ops makes every member rebuild and store without bound. | Door byte bounds (1 MiB an op, 16 MiB a checkpoint, `stateless_check`); `held` only from authors the set knows (256, 10 min, heaviest evicted); undecided ops under an order-independent max-min quota over charge trees (`ServerState::allocate`, 128 MiB per server, staff first up to 64 MiB); parked rows 128 KiB per tree, 30 days. | Rebuild CPU per backdated op (design E R4, no AR row, G-C1); a server past about 15,000 departed identities stops compacting (design section 16) | `an_op_past_its_byte_bound_is_refused`, `held_admits_only_known_authors_and_evicts_the_heaviest` |
| D | One op an older build cannot read wedges its sync, or a malformed batch panics the node. | `parse_ops_tolerant`; `read_op` keeps an unread member-signed op (bounded, fair per author) for the next build; page ingest runs in `spawn_blocking`. | none | `a_newer_build_folds_in_what_an_older_one_kept` |
| D | Honest ops lost when the owner checkpoints from a lagging view. | Writer rule: two witnesses, one a moderator or with admissions rooted in different members (`checkpoint_witnessed`); a refused own admission re-asks silently (`refused_own_admission`). | Decision 3 (today's authority) can undo an honest act whose authority a covered later op removed (design section 6) | `the_owner_checkpoints_only_after_two_witnesses_one_vouched`, `t14c_the_f1_cascade_heals_by_silent_re_asks` |
| E | A demoted, kicked or banned admin backdates grants to before its demotion or removal. | A kick or ban carries `seen` grant hashes; unseen power-granting ops in the span it closes are void (`crdt::voids::void_at_its_point`); only a removal that folds at its own point voids. | AR-11 (demotions, non-granting acts, the leave-and-readmit span, checkpoint-decided removals, the four-pass bound) | `a_refused_removal_leaves_the_tail_and_a_rebuild_equal` |
| E | A join snapshot sets the joiner's roles, bans or public flags. | `accept_join_snapshot`: 40-hex ids take none; with a pin only the pin's; it keeps only the owner's role (HOL-SEC-093). | AR-10 (unpinned 32-hex) | `authz_a_join_snapshot_carries_no_authority` |
| E | A moderator edits the owner or a higher rank, or mints ownership. | `op_allowed` edges (`role_change_allowed`, `kick_allowed`, `lifts_register`): owner fixed, edits only over lower ranks, permission bits only those held. | none | `op_allowed_ingest_matrix` |

### P3: op format and parsing

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| T | A field this build drops re-serializes to bytes the signature does not cover. | `read_op` verifies over the exact payload bytes (`raw_value`) and calls such an op unread, never a forgery. | none | `a_newer_build_folds_in_what_an_older_one_kept` |
| D | A deeply nested or oversized op exhausts the parser. | serde_json's recursion limit; the door's byte bounds before the fold. | Fuzzing of CRDT batches is a pre-freeze item (cargo-fuzz wire parsers) | none yet |

### P4: the transports

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| S | The carrier of an op is taken as its author, or a transport skips a gate. | All three transports enter only through `ingest_remote` (the MLS arm, the Olm twin, sync and page answers); the carrier only routes. | none | `op_allowed_ingest_matrix` |
| T | A page or digest answer nobody asked for is merged. | Pages count only from the asked device with the page's nonce; digest splits only for our open ask, malformed replies dropped whole (wiki section 40). | L2 (G-C1) | `review_one_members_junk_op_leaves_nobody_to_serve` |
| I | The relay reads ops. | MLS plus the carried Olm twin; the plaintext copy is dropped before any handler (design A lane rule). | none | `c24_server_traffic_rides_mls_or_olm` |
| D | A refused op still moves our clock. | Only an admitted op advances the HLC. | none | `authz_only_an_admitted_op_moves_our_clock` |

### DS1, DS2: the op store and RAM state

| Class | Threat | Mitigation | Residual | Test |
|---|---|---|---|---|
| T | A crash between the state and the rows leaves them disagreeing. | `persist_op_delta` in one SAVEPOINT, founding op never named; `restore_op_log` picks the base from the rows and checks `retained_print`, refolds once on a mismatch. | none | `persist_is_one_transaction_and_keys_the_founding_op`, `a_restart_through_the_store_matches_a_live_replica` |
| I | Op rows readable at rest. | SQLCipher with the identity-derived key. | AR-04 (an unlocked running device) | (storage suite) |
| D | Parked and held rows grow without bound. | 128 KiB parked per tree, rows past their time deleted at restart; `held` 256 per server. | none | `held_admits_only_known_authors_and_evicts_the_heaviest` |

### Flows and interactors

| Class | Threat | Mitigation | Residual |
|---|---|---|---|
| F-31 join answer, D | A joiner's answer carries the whole log in one frame the relay buffers. | `join_answer`: founding op, base, parent, the joiner's admission chain, then the newest ops within 256 KiB; digest catch-up pulls the rest. | none |
| X-4 sibling, S | Two devices of one identity mint the same op id. | Each device mints in its own counter lane (`Hlc::for_device`). | none (`two_siblings_same_ms_ops_both_survive`) |
| P-08 removed device, E | Keeps authoring after removal. | As P1 S, row 2. | **HOL-SEC-188** |
| X-3 owner away for months, D | Nothing compacts, logs grow. | Compaction only: nothing functional waits on a checkpoint; quotas bound what is undecided. | Size growth until the owner returns (design section 11) |

## Gaps for the lead

- **G-C1 (record, not a finding).** Two accepted residuals live only in the wiki and the
  design, with no row in `accepted_risks.md`: L2, an asked responder that withholds ops
  (wiki section 40), and design E R4, the rebuild cost of a backdated flood (left to the
  G1 measurement). A professional auditor reads the register first. Proposed: two rows,
  owner Vitalii, review at the G1 rerun.
- **G-C2 (decision, Info).** Every member folds the whole server state, so a member who
  cannot see a restricted channel still holds its name, category, settings and grants; the
  channel's content stays in its subgroup. Nothing in `claims.md` promises otherwise (C-18
  covers messages), so this is a decision to record, not a break: an AR row or a sentence
  under C-18.
- **G-C3 (stale record).** AR-12 ("an op older than a checkpoint's covers that the owner had
  not seen is dropped by every member") is what checkpoint coverage (56587ca2) removes. Its
  row still reads Accepted. Proposed: move it to Closed entries, "Closed in 0.14
  (2026-11-05, t14-cover)", with design section 16's own residuals named.

## State at 89d3a85d (2026-11-14)

This slice was read at `56587ca2`. What changed since, on `security/0.14`:

- **HOL-SEC-188 is fixed.** Track C (11d2619f, dcce6b29) built the device proof on every op,
  the verdict under `Roster::authority()` and the cut; the P1 S, R and P-08 rows above now
  have their gate (`requirements.md` R-CR-07, R-CR-12 to R-CR-15).
- **G-C1** is recorded: L2 is AR-45, design E R4 is AR-46.
- **G-C2** stays a decision for Vitalii (no claim promises otherwise).
- **G-C3** is done: AR-12 moved to the register's closed entries (closed in 0.14 by
  checkpoint coverage).
