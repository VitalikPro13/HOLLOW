# HOL-SEC-066: The client acted on values the relay chose

```
ID:          HOL-SEC-066                 Status: Fixed on local main (2026-09-29), retest at release
Severity:    Medium                      (Impact M: a friend request, its prekey bundle and device
                                          list sent to a master a squatter or the relay chose; every
                                          call's media routed through a TURN host of the relay's
                                          choosing; an Always-relay viewer's media leg opened to a
                                          person's device; one reply stopping the node and wiping the
                                          stored access key; Exploitability M: a squatted nickname, or
                                          the relay itself)
Category:    Trust boundary
Component:   rust/hollow_core/src/node/ws_client.rs :: connect_and_auth, turn_uris_on_relay;
             node/nick_claim.rs, swarm.rs (nickname, TURN and forwarder arms);
             lib/src/core/providers/license_key_provider.dart, forwarder_info_provider.dart,
             ui/shell/hollow_shell.dart, ui/dialogs/friends_manager_dialog.dart,
             ui/mobile/tabs/mobile_friends_tab.dart; relay-uws/src/ws_handler.cpp ::
             handle_claim_nickname, handle_resolve_nickname; validate.h
Boundary:    TB-1 (client <-> relay)
Traces to:   C-25; candidates A18, A26, J5, J7; relay inventory D, E.9, E.10, F
Attacker:    P-01 malicious relay; P-06 a nickname squatter
Found:       2026-09-26 (phase B: A18), 2026-09-27 (design A inventory: A26, J5, J7)
```

## Description

Four decisions rested on the relay's word. A nickname resolved to whatever master its
claimer typed, and the client sent a friend request, with our prekey bundle and signed
device list, to that master at once, with no step showing whom it went to. TURN URIs
were used whatever host they named, so with "Always relay calls" on, every call's
media went through a server the relay picked. The relay-named media forwarder was the
only one an Always-relay viewer accepted, and the relay could name a person's device.
Any reply containing `license_key` stopped the node for good, erased the stored access
key and asked for a new one, and that one key went to whichever relay was configured.

## Reproduction

`authz_a_nickname_names_only_a_master_that_signed_for_it`,
`authz_the_relay_cannot_name_a_known_person_as_its_forwarder` (node/test_harness.rs);
`turn_uris_must_name_the_relay`, `only_the_relays_exact_codes_are_license_refusals`
(node/ws_client.rs).

## Fix

- Nicknames: a claim is signed by the claimer's master over the nickname, the claiming
  device, the master and a time (`hollow-nick1`). The relay keeps only a claim that
  verifies for the socket making it, and hands the signature back on resolve; the
  resolver checks it again (master key derives the master, signed for the device
  holding the nickname, at most eleven minutes old). A lookup never sends anything:
  Dart shows "Send a friend request to {nickname}?" with the end of the master's ID,
  and only a confirm sends the request. Pre-0.12 unsigned claims are kept until 0.12
  ships (`ACCEPT_UNSIGNED_NICKNAME_CLAIMS`) but never resolve for a 0.12 client.
- TURN: only URIs whose host is the relay's own (the host the client dialled) reach the
  app or the embedded forwarder.
- Forwarder: a relay naming a known identity (a resolved device, a known master, our
  own device or master) is ignored; otherwise Dart pins the first forwarder a relay
  names and refuses another while the pinned one was seen online in the last week.
- License: only the relay's exact refusal codes count; a refusal never erases the key,
  keys are stored per relay domain (the pre-0.12 key moves to the relay configured at
  the first 0.12 start), and the forwarder stops only on a typed refusal.

## Test

The tests above, the updated `nickname_friend_request_reaches_multi_device_claimer`,
`nickname_claim_payload_matches_the_relays_pinned_vector` and
`a_nickname_resolves_only_to_the_master_that_signed_for_its_device` (node/nick_claim.rs,
the same vector pinned in test_relay_validators.cpp), test/forwarder_pin_test.dart (6),
and three new tests in test/widget/friends_manager_dialog_test.dart (the confirm names
the master's ID and nothing goes out before it, cancelling sends nothing and keeps the
nickname, an unverified claim says so at the field). Mutation pass: an unchecked TURN
host, license codes read by substring, a claim for any device, a claim key that is not
the master's, a resolver taking the relay's master, and a known person as the forwarder
each fail a test.

## Residual

The forwarder pin trusts the first advertisement: a relay hostile from the start can
name a forwarder of its own, which learns only what the relay already knows (the
viewer's address). Nicknames stay enumerable by design (a rendezvous). The license
dialog path has no widget test.
