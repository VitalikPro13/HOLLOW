# HOL-SEC-010: A member of any group we shared could post into another server or a restricted channel through MLS

```
ID:          HOL-SEC-010                 Status: Fixed on local main (2026-09-27), retest at release
Severity:    High                        (Impact H: posts into servers and restricted channels the sender does not belong
                                          to, and server-scoped handlers (deletion, kicks, voice joins) driven from an
                                          unrelated group, a meeting included; Exploitability M: needs membership in any
                                          MLS group the victim holds, and a meeting host admits whoever it likes)
Category:    Access control (authenticated but not authorised): MLS decryption proves the sender is in THAT group,
             never that the envelope inside belongs to it
Component:   rust/hollow_core/src/node/swarm.rs :: MlsChannelMessage dispatch
             rust/hollow_core/src/node/fetch.rs :: try_process_channel_msg (push path)
Boundary:    TB-2 (peer <-> peer)
Traces to:   C-14, C-16, C-18; candidate C2; server_mls S-10, transport S-07, media S-05, dm S-20 (typing)
Attacker:    P-05 member of any server or meeting the victim is in
Found:       2026-09-26, phase B channel, MLS, transport and media passes; confirmed by reading and test 2026-09-27
```

## Description

An `MlsChannelMessage` frame names a server (and, for a restricted channel, the
channel) so the receiver can pick the group that decrypts it. The envelope
inside names a server and channel of its own, and every handler acted on the
inner names. Nothing compared the two. A member of one group could therefore
encrypt, under that group, a post for a different server, or for a restricted
channel of the same server that it cannot see, and the receiver filed it there.
The same held for every other server-scoped envelope: a meeting host, who can
admit anyone to the meeting's group, could reach a real server's deletion and
kick handlers, which judge the author by the leaf credential alone (forgeable
until D1 is fixed), and a member of a shared server could announce itself in a
meeting's voice roster without passing its waiting room. DM-shaped typing
envelopes were accepted from any group as well.

## Reproduction

`authz_mls_envelope_must_fit_the_group_that_decrypted_it`
(node/crypto_handler.rs tests).

## Fix

`crypto_handler::mls_envelope_fits_group` runs on every decrypted envelope
before dispatch, live and on the push path:

- the envelope must name the server whose group decrypted it;
- a channel subgroup carries only its own channel;
- message content (posts, edits, cards, deletions, reactions, file headers,
  history) for a channel that is restricted in our state arrives only through
  that channel's subgroup, since senders never use the server group for it;
  presence, typing, voice and vault traffic ride the server group by design;
- DM-shaped envelopes never ride a group.

`MessageEnvelope::place` classifies every variant with an exhaustive match, so a
new variant cannot compile without a decision. `channel_ingest_gates_stay_wired`
fails if either receiver stops calling the check.

## Variants

- The leaf credential itself is unvalidated, so the sender's identity inside a
  group can still be forged (candidate D1, design piece D). Signed content is
  unaffected; unsigned server-scoped envelopes attributed by the credential are
  not, until D lands.
- Plaintext public-channel frames: HOL-SEC-009.
- Typing for a restricted channel rides the server group, so members who cannot
  see the channel learn that someone is typing there (metadata, low; noted for
  class C).

## Test

`authz_mls_envelope_must_fit_the_group_that_decrypted_it` fails when the check
accepts everything and passes with the fix. Full suite green.
