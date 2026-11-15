# HOL-SEC-014: A public channel served the text of deleted messages to any guest

```
ID:          HOL-SEC-014                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    Low                         (Impact L: text its author deleted from a public channel stays readable
                                          to strangers who never saw it; Exploitability H: any guest, with a client
                                          that shows what the page carries)
Category:    Information disclosure (deleted content served past its deletion)
Component:   rust/hollow_core/src/storage/messages.rs :: get_channel_messages_before (now
             get_visible_channel_messages_before); node/swarm.rs :: PublicChannelSyncRequest responder
Boundary:    TB-2 (peer <-> peer), TB-1 (relay)
Traces to:   candidate C9 (evidence channel:S13)
Attacker:    P-03 stranger browsing a public channel as a guest
Found:       2026-09-26, phase B channel pass; confirmed by reading and test 2026-09-27
```

## Description

Members keep a deleted message's text on purpose: it is evidence (the Rat
Files), and the deletion proof is signed over it. The page a member serves to a
guest browsing a public channel came from the same query, so it carried deleted
rows with their full text next to the hidden flag. The guest interface hid them,
but the text was on the wire in the clear for every stranger who asked.

## Reproduction

`guest_pages_leave_deleted_messages_out` (storage/messages.rs tests).

## Fix

The guest page query leaves deleted rows out
(`get_visible_channel_messages_before`), so a page is never short of visible
messages and a stranger never receives what the author deleted. Members' own
sync still carries deleted rows with their proofs, as the Rat Files require.

## Variants

- A guest that was watching live when a post was deleted receives the plaintext
  delete frame and removes it; nothing is stored on a guest.
- The relay saw the original public post when it was sent; this closes only the
  replay of it after deletion.

## Test

The test fails with the old query (both rows served) and passes with the fix.
Full suite green.
