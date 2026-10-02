# Design ID-1R: the relay learns rosters

Session 25 (2026-10-02, xhigh). The relay half of design ID-1
(`design_ID1_identity_authority.md`, its section 9 decision 2): who may read an identity's
inbox. Closes HOL-SEC-078 and AR-15's inbox half. Building it found three gaps in ID-1's
fold, fixed here because the relay mirrors that fold: HOL-SEC-079, HOL-SEC-080 and
HOL-SEC-081.

## The problem in one paragraph

The relay let a socket own `inbox:{master}` (read the mailbox of friend requests and
replies, see the identity's other devices and when they are online, take deposits for the
master live) when it showed a device list the master key signed naming its device. After
ID-1 the master key admits no device, yet anyone holding it, a restored backup or a removed
thief's phone, signed such a list naming itself, and by signing one at a huge version
locked the real devices out of their own mailbox.

## The design

1. **The inbox join carries the device's own roster** (`inbox_roster`, the JSON every
   carrier already sends). A plain join carries nothing and owns nothing new.
2. **The relay holds one roster per identity** (`relay-uws/src/roster_book.h`) and folds
   every roster shown for it into that one: the same verification, merge, compaction and
   fold as the apps (`relay-uws/src/roster.h`, rule for rule `identity/roster.rs`). Every
   statement verifies alone, so a roster shown by anyone is folded; who showed it decides
   nothing.
3. **A socket owns the inbox only while its device is a member of the held roster.** A
   shown roster decides for its socket on its own; a plain re-join keeps an owner an
   owner. Removals and a newer recovery stay once any device has shown them, so no older
   roster takes them back, and the first recovery key held is pinned.
4. **A change drops at once every owner the held roster stops counting**; the owners left
   see it leave. Every device shows its roster on every connect and after every change to
   it, the remover included (`roster_book::show_relay`).
5. **Pending joins count seven quiet days on the relay's own clock**, from when it first
   saw them in the current base, like every contact (Vitalik, 2026-10-02), unless the
   phrase turned the wait off (below). A device that stops asking is forgotten, and a
   recovery starts every clock over (HOL-SEC-082: kept per device, a backup the phrase
   left out rejoined at once).
6. **Bounded and kept across restarts.** The registry is a `FairShare` table of 128 MB,
   charged to the share of the member who last showed the roster (a stranger showing it
   first never makes it theirs to lose); it rides the restart snapshot (codec v7: each
   roster as JSON with the ages of its first sights), never disk. A roster past any
   ceiling, over 256 KiB, or for another master counts nobody and is not verified.
7. **The 0.11 proof until release day.** A master-signed list is still read
   (`ACCEPT_DEVICE_LIST_INBOX_PROOF`, version marks as before), and never for an identity
   whose held roster the phrase roots or for a device it removed. Off once 0.12 ships, with
   the other `ACCEPT_*` switches.

**Until release day, mixed identities:** a 0.11 device that owns an inbox through its
list is in no roster (it never signed a consent), so the next roster change for that
identity drops it until its next connect proves the list again, and once the phrase roots
the identity on 0.12 its 0.11 devices own nothing there. Both are the design: those
devices are not members. After 0.12 ships the list path is off.

What the relay learns is no new exposure: rosters already ride in the clear as
`RosterNotice` (so a contact that refuses a device can still hear it), and the relay
already grouped one person's devices by who joins their inbox. It keeps the statements in
RAM to answer one question.

## Decision: the wait can be turned off (Vitalik, 2026-10-02)

The seven-day wait stays the default: it is how someone who lost every device and the
phrase comes back from a backup (Signal's registration lock has the same shape). A person
can turn it off. The choice is a field of the phrase's recovery statement (`no_wait`,
inside its signature, payload suffix `:nowait`), so every contact and the relay enforce it,
only the phrase changes it either way, and nobody holding the master key can strip it.
Settings > Security > Advanced, "Let restored backups join on their own"; changing it signs
a recovery that keeps every current device (`set_backup_wait`), so a device waiting at that
moment asks again: the change reaches it in the identity's own room, and a device a new
base leaves out signs a new ask at once. With the wait off, the waiting screens promise no
date and the device still waits behind its lock.

## The fold, as fixed here

- **Standing** (HOL-SEC-079). Compaction ranks every device with an admission path in the
  current base: tier 0 grows from the phrase's roots (legacy claims in a legacy base),
  tier 1 from pending joins (anyone holding the master key can sign one), depth counts
  vouches from a root. A vouch or removal stays only when its signer
  stands, whatever it names (a vouch may precede its device's consent, a removal may
  precede the device's claim), ordered by its signer's rank before the ceilings cut (128
  vouches, 96 removals with at most 16 kept each). Each standing device's best vouch stays
  first, so compacting a compacted roster changes nothing. Consents: standing devices
  first, then named ones, then at most 8 unnamed, 96 in all. The largest roster is about
  198 KB of the 256 KiB wire limit.
- **Kept vouchees are an intersection** (HOL-SEC-080): a removed device keeps only the
  vouchees every removal of it keeps.
- **A self-removal keeps the device's vouchees** (HOL-SEC-081).

## Tests

Units in `identity/roster.rs` (the flood, tier, intersection, no-wait, stability and size
tests), `node/roster_book.rs` (`the_relay_is_shown_the_whole_roster`,
`removing_itself_keeps_the_devices_it_linked`), `node/ws_client.rs`
(`test_join_message_carries_the_roster`). Harness, with the mock relay folding rosters as
the relay does: `authz_the_master_key_alone_never_owns_a_protected_inbox`,
`authz_a_removed_device_loses_the_inbox_at_once` (the removed device hears nothing, so only
the remover can tell the relay), `mailbox_requires_a_roster_that_counts_the_device`.
Relay: `test/test_roster.cpp` replays the 117 cases `identity/roster_vectors.rs` writes to
`test/roster_vectors.json` (random and adversarial rosters, identities built the honest
way, the ceilings, the relay's seven days and the flag), each matched byte for byte, plus
JSON strictness, the book and fair share; `test_snapshot_codec.cpp` covers v7 and reads
every older version; all under ASan and UBSan. A canary on port 8443 and then production
passed a live probe of 19 checks (`inbox_probe.py`, on the relay box). Widget:
`pending_device_dialog_test` (the seven days are promised only while they apply). Mutation
pass: see section "As built".

## Residuals (AR-15)

- **After the relay box reboots** (a service restart keeps the registry), the first roster
  shown for an identity sets its recovery key there: a master-key holder who shows a forged
  one first holds that inbox on that relay until the next reboot. Nothing in an identity's
  id commits to its recovery key, so no relay can tell the two apart without history.
- **A member that floods** its own base pushes out devices deeper than itself, which it
  could remove anyway; the phrase ends it.
- **A thief's own vouchees** made before its removal are kept by the app's default keep
  list until removed too.
- **CPU**: a shown roster can cost the relay a few hundred signature checks (statements
  it already holds are not checked again); phase G measures and limits it.
- **Verifier difference**: the relay checks with libsodium, the apps with ed25519-dalek's
  `verify_strict`; libsodium refuses what `verify_strict` refuses for these keys, so the
  relay is never the more permissive one.

## As built

Mutation pass `tmp_id1r_mutate.py` (session 25): 13 of 14 rules fail a named test when
broken. The first run let three survive (the signer-rank order for vouches and for
removals, the best-vouch-first rule), because the flood test's key ids happened to sort
the owner's statements early; `authz_signer_rank_decides_what_a_full_roster_keeps` and
`a_deep_device_keeps_its_only_vouch_in_a_full_roster` pick keys so the plain order would
lose them. A fourth survivor showed a 64-device cap on standing was redundant (the vouch
ceiling already keeps compaction stable, and the cap only silenced a 65th device), so it
was removed from both the apps and the relay, and the relay redeployed. The one survivor
left is an equivalent mutant: "a shown roster decides on its own" is defense in depth,
since every change already demotes the owners it stops counting.
