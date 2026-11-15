# HOL-SEC-100: A removed author could still rewrite and re-card its old posts

```
ID:          HOL-SEC-100                 Status: Fixed on local main (2026-10-03), retest at
                                          release
Severity:    Low                         (Impact: a kicked or banned author changes its own posts after removal;
                                          Exploitability M: the removed author's own key)
Category:    Channel / Authorization
Component:   rust/hollow_core/src/node/message_ops.rs (live_channel_change_refusal,
             handle_envelope_edit_message, handle_envelope_link_preview_set)
Boundary:    TB-3 (server members)
Traces to:   C-16; phase B re-check channel A-CH03, A-CH06
Attacker:    a removed member
Found:       2026-10-02 (phase B re-check)
```

## Description

Live edits and link-preview cards checked only that the sender was not muted and wrote the row. A kicked or banned author could therefore keep rewriting and re-carding its old posts over Olm or on public channels; MLS was closed only because the kick removed its leaves.

## Fix

One ladder, `live_channel_change_refusal` (a member, who can see the channel, not muted), now judges every live edit, card and reaction, and the post gate asks it first. With no server state (a guest) nothing is judged, as for posts. Sync backfill is unchanged (live enforces, backfill tolerates).

## Test

Unit `authz_a_removed_author_no_longer_edits_or_recards_live` (failed before: "a removed author rewrote its post live"); the wiring scan `channel_ingest_gates_stay_wired` covers the three handlers; mutation killed.
