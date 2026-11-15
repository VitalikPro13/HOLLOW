# HOL-SEC-005: Any identity could delete another user's identity and messages, or take their identity with one click, through the device-link flow

```
ID:          HOL-SEC-005                 Status: Fixed on local main (2026-09-26), retest at release
Severity:    Critical                    (Impact H: identity and message database deleted at the next launch, or the
                                          identity replaced; Exploitability H: any authenticated identity that knows the
                                          victim's public master id, no relationship needed)
Category:    Access control (a flow that trusts every frame that claims to belong to it)
Component:   rust/hollow_core/src/node/swarm.rs :: LinkSnapshotRequest / LinkSnapshotKey arms
             rust/hollow_core/src/node/link_handler.rs :: handle_inbound_link_key, handle_inbound_link_request
             rust/hollow_core/src/node/file_handler.rs :: handle_link_snapshot_stream
             rust/hollow_core/src/api/storage.rs :: import_pending_link
             lib/src/ui/shell/hollow_shell.dart :: _bootstrap (runs the import at every launch)
Boundary:    TB-2 (peer <-> peer), TB-1
Traces to:   C-02, C-05; attack tree AT-1 ("any other path to the wipe routine"), AT-2; authz rows A-ID-20..22
Attacker:    P-03 stranger (anyone who can join the victim's inbox room, which is every authenticated socket), P-01
Found:       2026-09-26, phase B (identity and relay enumeration passes, independently), confirmed by reading and test
```

## Description

Device linking has two halves and neither checked who it was talking to.

**The empty device (wipe).** `LinkSnapshotKey { link_id }` registered a pending
snapshot for ANY sender, with the passphrase `my_link_code()`, which is `""`
when no link was ever started. A `TYPE_LINK` stream frame from any sender was
then assembled with no gate and handed to `handle_link_snapshot_stream`, which
only checked that the id was registered. It stashed the blob as
`pending_link.hollow`. At the next launch `_bootstrap` calls
`import_pending_link`, which DELETED `identity.key`, `identity.device` and
`messages.db` first and only then tried to decrypt the blob. A garbage blob
leaves the user at the Welcome screen with everything gone; a real `.hollow`
exported with an empty passphrase makes the victim's device load the
attacker's identity.

**The populated device (one-click theft).** `LinkSnapshotRequest` from any
sender raised the global "Your other device is asking to sync" prompt. With no
link code claimed, Accept encrypts the full backup (master key included) with
the public master peer id and streams it to the requester, who decrypts it.

The inbox room `inbox:{master}` is joinable by any authenticated socket (relay
row A-02), and a master id is public to every friend, server member and guest.

## Reproduction

`authz_link_frames_from_a_stranger_are_refused` (node/test_harness.rs): before
the fix, link frames from a stranger raised the sync prompt and stashed a
snapshot for the next launch.
`pending_link_import_keeps_the_identity_when_the_blob_does_not_open`: before the
fix, that launch deleted the identity for a blob that never opens.

## Fix

- The empty device records the peers it sent a `LinkSnapshotRequest` to
  (`link_handler::note_snapshot_asked`, both request paths). `LinkSnapshotKey`
  registers only for such a peer and only while a code is set, and the pending
  state keeps the announcing sender; the stream completes only from that sender.
- The populated device raises the prompt only for a requester in the room of the
  code it claimed, or for one of its own devices (`link_request_allowed`).
- `import_pending_link` decrypts the blob and checks it holds `identity.key`
  BEFORE deleting anything; a blob that does not open costs nothing.
- Long term: the link protocol is replaced together with HOL-SEC-002 (PAKE or a
  confirmed ephemeral exchange) and design ID-1's vouched join.

## Variants

- Every flow whose later frames are accepted because an earlier frame "opened"
  it: file headers and chunks (candidate H1, H3), shard streams (H10, H14),
  recovery pool (H16), parked joins (A5), conference lobby (A16).
- Every "delete then import" or "drop then rebuild" ordering: the MLS Welcome
  drops the live group before validating (D3), the Olm rebuild dropped the
  session before authenticating (HOL-SEC-003).

## Test

`authz_link_frames_from_a_stranger_are_refused` and
`pending_link_import_keeps_the_identity_when_the_blob_does_not_open`: both failed
before the fix, pass after; 60 existing link, sibling, backup and destroy tests pass.
