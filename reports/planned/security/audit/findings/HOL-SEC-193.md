# HOL-SEC-193: A carried profile card or update keeps a roster for any identity its sender's device signed

```
ID:          HOL-SEC-193                 Status: Fixed on local branch security/0.14
                                          (track t14-prof, 2026-11-05), retest at release
Severity:    Medium                      (Impact M: unbounded growth of the roster book
                                          and the card store, and the resolver re-points
                                          the sending device to each minted identity;
                                          Exploitability M: needs one Olm session with
                                          us, which any co-member, a public server's
                                          included, a friend or a meeting peer holds)
Category:    Resource exhaustion / Unbounded state from a peer
Component:   rust/hollow_core/src/node/swarm.rs (Carried ProfileCard and ProfileUpdate
             arms, MLS ProfileUpdate), social.rs (handle_envelope_profile_update),
             roster_book.rs (ingest, fold_in_store), conference.rs (meeting card line)
Boundary:    TB-1, TB-2
Traces to:   HOL-SEC-192 residual; track I's R31-8 (notice_may_be_kept) gates only
             RosterNotice and RosterSync
Attacker:    P-02 co-member, friend or meeting peer with a modified client
Found:       2026-11-05 (t14-flood, harness probe on 33024bdb; the code is the same on
             main 8350841b)
Affected:    every release from 0.12.0 (profiles phase D: cards and rosters ride profile
             messages) through 0.13.0
Fix commit:  a58d7f38 (security/0.14, 2026-11-05)
Embargo:     EMBARGOED until the 0.14 release (local branch security/0.14, never pushed);
             advisory with the 0.14 GHSAs
```

## Description

The `ProfileCard` and `ProfileUpdate` arms pass their `device_list` to
`roster_book::ingest` before any relationship check, and nothing binds that roster's
master to the sender's identity. A first sight is kept whenever the delivering device is
a member of the roster, and a device can consent to any number of rosters for identities
its owner mints. The card check that follows (`card.master == resolve(sender)`) passes
too, because the ingest has just pointed the resolver at the new master. One session
therefore grows the roster book and the card store without limit. The probe left 40
minted rosters and 40 cards in the receiver's store from one co-member.

## Fix

One gate, `roster_book::admit_profile_roster` over `notice_may_be_kept` (a synchronous
check, so the swarm handler's awaited futures keep their size), runs before the ingest
in the Carried `ProfileCard` arm, the Carried `ProfileUpdate` arm and the MLS
`ProfileUpdate` (`social::handle_envelope_profile_update`). A carried roster is kept only
on `notice_may_be_kept`'s terms: our own master, a master we hold a roster for, a friend
row of any state (by master, or by the delivering device for a nickname friend), or a
master a server we hold names. An MLS leaf's certified master admits nothing by itself:
a server group's leaves are members, which the server term already covers, and a
meeting's host seats any leaf. A refused roster drops the whole message: the card, the
profile and the card a profile carries (the MLS caller's `keep_card` too), so a refused
roster's message writes nothing. The MLS `keep_card` binds the card to the leaf's
certified master instead of the resolver. The push fetch handles no profile message.

A `ProfileUpdate` decrypted in a meeting group drops before the handler
(`conference::refuses_profile_update`): honest clients broadcast it only to the servers they hold, and a
meeting shows only the card its group line carries. That card line keeps cards for at
most 256 identities per meeting while we sit in it (`MEETING_CARD_IDENTITIES`, RAM, per
our master and meeting, cleared when we leave or end it); past it a new identity's card
is refused, never another's evicted, since every seat in a meeting is its host's to give.
Keeping meeting cards in RAM only was weighed and set aside: every profile reader (the
FFI profile and avatar calls, the overlay looks, the Dart profile provider) reads the
store, so a RAM card would need a second source through all of them.

Every other `roster_book::ingest` caller is gated elsewhere: `RosterNotice`/`RosterSync`
(R31-8), the push fetch roster trade (`roster_reach::fetch_roster`, same check), DM
carried removals (`ingest_carried`, only a device of the DM's identity, never a first
sight), a friend roster from a sibling (own unrevoked devices only), and FriendRequest,
FriendAccept, FriendReject and ServerJoinRequest (HOL-SEC-192, track t14-flood).

## Residual risk

The roster book and the card store are never pruned. A master a held server names
passes, so a server owner or admin who adds and kicks minted identities, or minted
identities that join an open server, send one profile and leave, grow both with the
server's op log (an op's author stays named), and the rows outlive checkpoints and the
membership; the member cap bounds only how many are members at once, not the total
over time (the same family as the R31-8 notices and HOL-SEC-192's residual). A meeting
host still writes up to 256 cards per meeting a guest joins, and they stay after the
meeting. Follow-up (not built): roster and card GC, dropping rows for masters that no
held server, friend row or our own identity names.

## Test

Harness `rev193_a_meeting_hosts_churned_strangers_fill_a_guests_roster_book` (a meeting
host seats three fresh identities that each send an MLS `ProfileUpdate` and leave;
before the fix the guest kept "3 rosters and 3 full profiles"),
`rev193_b_a_meeting_hosts_churned_strangers_fill_a_guests_card_store` (the same churn
over the card line, the meeting's share set to 1; before the fix "3 cards"; the host's
card still updates), `t14p_a_meeting_carries_no_profile_update_even_from_a_friend` (the
meeting drop alone: a friend row passes the roster gate) and `probe193_a_co_members_cards_fill_the_roster_book_with_minted_identities`
(Carried `ProfileCard`: 40 minted rosters and cards, then a card of the sender's own
identity carrying a refused roster),
`probe193_b_a_co_members_profile_updates_over_olm_keep_no_minted_identity` (Carried
`ProfileUpdate` with its card) and
`probe193_c_a_co_members_profile_updates_over_mls_keep_no_minted_identity` (MLS). The
probe193 tests each fail without the gate ("left 40 minted rosters and 40 cards", "left 12 minted rosters
and 12 cards", and on MLS the resolver was re-pointed so far that the honest profile
never landed) and checks the sender's honest card or profile still lands. Units
`a_profile_roster_for_a_minted_master_is_refused`,
`a_strangers_own_profile_roster_is_refused`,
`a_profile_roster_from_siblings_friends_and_co_members_is_kept`, source scan
`the_profile_roster_arms_go_through_the_gate` (also pins the meeting drop before the MLS
handler).
