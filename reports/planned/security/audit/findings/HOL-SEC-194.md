# HOL-SEC-194: A member served a public channel's deleted posts, and their files, to a non-member

```
ID:          HOL-SEC-194                 Status: Fixed in 0.14
                                          (c7caff62, 2026-11-05)
Severity:    Low                         (Impact L: text and files their author deleted from a
                                          public channel stay readable to a stranger who never
                                          saw them; Exploitability M: needs a modified client
                                          and one Olm session with a member device, which a
                                          stranger gets at first contact in a server with a
                                          public channel)
Category:    Information disclosure (deleted content served past its deletion)
Component:   rust/hollow_core/src/node/swarm.rs (HavenMessage::ChannelSyncRequest responder,
             HavenMessage::FileRequest channel arm)
Boundary:    TB-2 (peer and peer)
Traces to:   HOL-SEC-014 (the same leak on the guest page); STRIDE pass on public channels,
             gap G-P1; hostile review of the first fix
Attacker:    P-03 stranger who knows the server id of a server with a public channel
Affected:    every release with public channels through 0.13.0 (before 0.11.1 the sync
             responder had no requester gate at all, closed then for non-public channels)
Found:       2026-11-05 (docs-only STRIDE pass, confirmed by a harness probe on 56587ca2;
             the code is the same on main 8350841b)
Fix commit:  c7caff62 (0.14, 2026-11-05)
Disclosure:  advisory with the 0.14 GHSAs
```

## Description

Members keep a deleted post's text and file on purpose: they are evidence, and the
deletion proof is signed over the post. A member's channel sync page therefore carries
deleted rows with their text next to the proof.

Two member paths handed that evidence to non-members of a public channel:

- The `ChannelSyncRequest` responder gated on `channel_readable_by`, which admits anyone
  for a public channel, since reading is what public means, and then served the member
  page with its deleted rows. HOL-SEC-014 had closed the same leak on the guest page
  (`PublicChannelSyncRequest`) only.
- The `FileRequest` channel arm served a public channel's file to a non-member on the
  public rung without asking whether its post had been deleted.

## Fix

- The `ChannelSyncRequest` responder serves only a current member who may see the
  channel (`crypto_handler::sync_partner`: not revoked, `is_member` on the resolved
  master, `can_see_channel`), the same rung a node uses to choose whom it asks. Anyone
  else gets silence, as a non-member already got for a non-public channel. A public
  channel's readers have the guest page, which leaves deleted rows out. The page itself is
  unchanged, so members keep the evidence.
- The `FileRequest` arm answers a non-member with silence when the file's post is hidden
  (`get_channel_message_hidden_at`), on the public rung too. Members are still served.

A first fix that served non-members a filtered page was dropped after review: such a page
still showed where deleted rows lay (page size, `has_more`, the gap digest's re-served
days), could stall behind a run of deleted rows, and moved the watermarks of a member the
responder could not place yet past rows it never got. With the refusal, such a member
receives nothing and gets its full history, deleted rows included, on its next ask.

Every sender of `ChannelSyncRequest` (the catch-up coordinator, the post-Welcome and
recovery asks, `ask_channel_holders`) is a node that holds the server and asks a
`sync_partner`; guests use `PublicChannelSyncRequest` only. No MLS or Olm twin of the
responder exists any more. The never-filled `pending_sync_requests` queue, whose flush
built the same page with no requester gate, is deleted.

## Residual risk

A member whose device the responder cannot place yet (a new device, a phrase-recovered
install) gets no page from that responder until its roster arrives, and retries; this was
already the case for every non-public channel.

## Test

Harness `a_non_member_channel_sync_ask_gets_no_deleted_text`: a stranger with an Olm
session asks a member for a public channel holding a kept and a deleted post. Before the
fix the batch carried the deleted post's text; after it the stranger gets no member page
at all, while its guest page from the same member arrives without the deleted post.
Harness `a_stranger_gets_no_file_of_a_deleted_public_post`: the stranger asks for the
deleted post's file and then the kept post's file; it gets the kept one and nothing of
the deleted one. Units `a_public_channels_sync_page_goes_only_to_a_member` (the gate
against the public carve-out) and `a_member_once_refused_gets_its_old_evidence_on_the_retry`.
The member path stays covered by `synced_channel_deletion_hides_for_late_joiner`.
