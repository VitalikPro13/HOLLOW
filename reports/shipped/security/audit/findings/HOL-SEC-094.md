# HOL-SEC-094: A channel restricted after it was public stayed public

```
ID:          HOL-SEC-094                 Status: Fixed on local main (2026-10-02), retest at
                                          release
Severity:    Medium                      (Impact M: posts in a channel the admins had closed
                                          to most members went out unencrypted, readable by
                                          the relay and any guest, and guests saw the channel
                                          listed; Exploitability H: no attacker needed, an
                                          admin closing a public channel was enough, and any
                                          admin could flag a closed channel public again)
Category:    Information disclosure
Component:   rust/hollow_core/src/crdt/server_state.rs :: ChannelInfo::effective_public,
             op_allowed (ChannelPublicChanged), apply (visibility changes)
             rust/hollow_core/src/node/sync_handler.rs :: handle_set_channel_public,
             handle_set_channel_visibility, handle_set_channel_visibility_labels
Boundary:    TB-1 (client to relay), TB-4 (server members)
Traces to:   C-16; decision D6 (2026-10-02, "hidden channels must never show")
Attacker:    none (an honest admin's order of actions), or P-05 admin
Found:       2026-10-02 (phase B re-check, while checking D6)
```

## Description

Whether a channel is public was read from its public flag and its type alone. Restricting
a public channel (a role tier or an access label) left the flag set, so the channel stayed
public: members posted into it as plaintext public messages instead of encrypting them to
the channel's own group, members answered guests with it in the channel list, and the
public flag could also be set on a channel that was already restricted.

## Fix

A restricted channel is never public, whatever order its settings changed in: the
public test requires an unrestricted channel, restricting a channel clears its public
flag for good (lifting the restriction later does not reopen it to guests), and every
member refuses an op that flags a restricted channel public. The admin who closes a
public channel tells the room's guests it is gone; the app refuses the public switch on
a restricted channel with a message.

## Test

Unit `authz_a_restricted_channel_is_never_public` and harness
`authz_a_hidden_channel_never_shows_to_a_guest` (both failed before the fix: "restricting
closes it", "O holds a closed channel public"); mutation pass in the session notes.
