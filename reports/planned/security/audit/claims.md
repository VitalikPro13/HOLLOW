# Hollow's security claims

What Hollow promises its users, one testable sentence each. Every threat,
requirement, matrix row and finding in this audit traces back to a claim. A
finding that traces to no claim means a claim is missing: add it here.

Written 2026-09-26 (audit phase A), from WHITEPAPER.md sections 2-23,
CLAUDE.md's rules and the product's own copy. **Vitalik approves this list**:
these are the promises, so they are his to make or withdraw.
**Approved by Vitalik 2026-09-26**, with every claim still to be verified by
the audit; C-23 withdrawn (AR-03).

Columns:
- **Against**: the attacker profiles (threat_model.md section 1) the claim
  must hold against. "All peers" = P-03 to P-08, each running any client
  they like.
- **Source**: where we already promise it.
- **Status**: `Believed` (no known break, not yet verified by this audit),
  `Broken` (a finding exists), `Overclaimed` (the public wording promises
  more than the design gives), `Undecided` (Vitalik decides whether we
  promise it).

## Identity and devices

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-01 | Only my own master key can add, revoke or rebind my devices. No message from any other identity changes which devices count as mine, or which devices count as someone else's. | P-01, all peers | WP 3.2, 23.1 | Broken, fixed on branch (HOL-SEC-001) |
| C-02 | Nothing another identity sends can wipe, lock or destroy data on my devices. Only my own master's destroy order, or my own duress secret typed on the device, can. | P-01, all peers | WP 23.1 | Broken, fixed on branch (HOL-SEC-001) |
| C-03 | Once I revoke a device, everyone who has seen the revocation stops sending it DMs, server messages and media keys, and its old sessions are dropped. | P-01, P-08 | WP 3.6 | Overclaimed today; design ID-1 agreed to make it true (note 1) |
| C-04 | A replayed older device list can never un-revoke a device. | P-01, all peers | WP 3.2 | Believed |
| C-05 | Linking a new device hands my identity only to that device, and only after I confirm on a device I already hold. Neither the relay nor anyone else learns anything from the transfer. | P-01, P-02, all peers | WP 3.4 | Broken (HOL-SEC-002) |
| C-06 | A copy of my identity file is useless without my machine (keychain mode) or my password (password mode). | P-09 | WP 2.3, 23.1 | Believed; "no protection" mode excluded by design |
| C-07 | Typing the duress secret destroys local data and shows nothing, and checking it costs the same as checking the real secret. | P-09 | WP 23.1 | Believed |

## Direct messages and friends

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-08 | Only the two people in a DM (and their own devices) can read it. The relay, the network and everyone else see ciphertext. | P-01, P-02, all peers | WP 4 | Believed |
| C-09 | A message shown as coming from a person was signed by that person's master key, and its text, attachments and album binding are exactly what they signed. | P-01, all peers | WP 15 | Believed |
| C-10 | The relay cannot insert itself into a key exchange, and cannot make me encrypt to a device that is not really my contact's. | P-01 | WP 23.1 (MITM) | Believed (fixed 0.8.2) |
| C-11 | Comparing safety numbers verifies the person, and I am warned when a verified contact gains a new device. | P-01, all peers | contact verification | Believed |
| C-12 | A friend request or accept creates a friendship only with the identity that signed it, and an accept only answers a request I actually sent. | P-01, all peers | friend accept binding | Believed |
| C-13 | A blocked identity's DMs, requests, calls and files are dropped before they are stored or notified, from every one of their devices. | P-04, P-06 | WP 12.14 | Believed |

## Servers and channels

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-14 | Server content is readable only by current members. A removed or banned member cannot read anything sent after the removal. | P-01, P-05 | WP 5, 23.1 | Believed |
| C-15 | Only holders of the required role can change server state (roles, channels, permissions, bans, kicks, ownership), and an operation claiming a false author is rejected by every client. | P-01, P-05 | WP 11, 23.1 | Believed |
| C-16 | Only the owner can delete a server. | P-01, P-05 | server delete tombstone | Believed |
| C-17 | Nobody can post, edit, delete or react as someone else, and mutes and bans are enforced by every receiving client. | P-01, P-05 | WP 15, moderation | Believed |
| C-18 | A restricted channel's messages, live and historical, reach only the people allowed to see that channel. | P-01, P-05 | #32, backfill gate | Believed |
| C-19 | Neither the relay nor any single member can add someone to a server's encryption group without the admission rules being met. | P-01, P-05 | WP 5 | Believed; see lead L-03 |
| C-20 | A public channel's messages are signed by their authors and cannot be forged, even though they are not encrypted. | P-01, all peers | public channels | Believed |

## Calls, voice and screen sharing

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-21 | Call, voice, video and screen-share media are readable only by the participants. The relay, TURN and a media forwarder see ciphertext only. | P-01, P-02, P-10 | WP 6 | Believed; see lead L-01 |
| C-22 | My screen share streams only to people who asked to watch it. | all peers | #38 | Believed |
| C-23 | Inside a call, a participant cannot make their media appear to come from another participant. | P-05 | none | Withdrawn: not promised, accepted risk AR-03 |

## The relay and metadata

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-24 | A fully malicious relay sees routing metadata only: device peer ids, which rooms they are in, and the timing and size of traffic. From that it can tell which devices belong together and who talks to whom. It never reads content, profiles, names, server or channel details, friend lists, read state or any other data. | P-01 | WP 3.1, 23.1 | Reworded 2026-09-28 (Vitalik); being built as design A-D1, see note 2 |
| C-25 | A malicious relay can delay or drop traffic, but cannot forge a message, a server change, a device list, a friend accept or a destroy order. | P-01 | WP 23.1 | Believed |
| C-26 | Apple, Google and UnifiedPush distributors receive only a wake-up and a sender id, never message content. | P-11 | WP 13 | Believed |
| C-27 | Reading a message with a link preview makes no request from my device to the linked site. | P-12 | WP 23.1 | Believed |
| C-28 | An invite link never reveals the server id to the website that serves it. | P-12 | deep linking | Believed |

## Files, assets and credentials

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-29 | Nothing a peer sends can write a file outside Hollow's own folders or choose where it lands. | all peers | filename sanitisation | Believed (fixed twice) |
| C-30 | File contents are end-to-end encrypted in transit, and content files at rest are unreadable without the identity. | P-01, P-02, P-09 | WP 7, 23.1 | Believed |
| C-31 | An emote, sticker, avatar or banner shown for a hash is exactly the bytes of that hash, and assets nobody asked for are dropped. | P-01, all peers | asset rail | Believed |
| C-32 | A support or Twitch credential on a profile was issued by the shop's pinned root for that identity and cannot be moved to anyone else. | all peers | WP 19, 20 | Believed |

## Updates and distribution

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-33 | The app installs only updates signed by Hollow's offline release key and never offers a downgrade. | P-10 | WP 23.4 | Believed |
| C-34 | A Flatpak installed from Hollow's repository accepts only bundles signed by Hollow's key. | P-10 | WP 23.4 | Believed |

## The device in someone else's hands

| ID | Claim | Against | Source | Status |
|---|---|---|---|---|
| C-35 | With App Lock on, no message content, name or notification is visible until unlock, and nothing appears above the lock screen. | P-09 | app lock | Believed |
| C-36 | Someone holding my locked phone cannot guess my App Lock PIN by copying the app's data. | P-09 | none yet | Undecided; see lead L-07 |
| C-37 | Logs never contain message content, keys, codes or passphrases. | P-09, support channels | logging rules | Believed |

## What we do not promise

Stated so nobody reads a promise into silence (WP 23.2 plus what this audit
adds):

- Traffic analysis: timing and size are visible to the relay and the network.
- A compromised, unlocked, running device: whoever controls it reads what you
  read.
- Relay availability: a relay can drop or delay; there is no failover yet.
- Post-quantum security: key exchanges are Curve25519 today.
- Trust on first use: identities are verified by comparing safety numbers.
- Sender authenticity of media frames inside a group call (see C-23).
- The relay sees which device ids share which rooms, and that is how it routes.

## Notes

1. **C-03 and the master key on every device.** WP 3.6: "all of a person's
   devices hold the master key". Revocation therefore binds an HONEST revoked
   device, which wipes itself. A thief with a stolen, usable device holds the
   master key and can sign a higher-version list that un-revokes itself and
   revokes the owner's real devices, which then wipe themselves. It can also
   issue master-signed destroy orders. The claim holds only while the stolen
   device cannot use its key (password mode and the device locked). The
   public "Stolen/lost device" row in WP 23.1 promises more than this. Decided
   2026-09-26: design ID-1 (the recovery phrase as the root of authority) fixes
   it; see the plan and AR-02.
2. **C-24 and the relay assumption.** WP 23.3 assumes the relay is
   honest-but-curious. The Matrix attacks of 2022 all came from a malicious
   homeserver, and anyone can run a Hollow relay. This audit assumes an
   actively malicious relay (P-01) everywhere. WP 23.3 gets rewritten at
   close-out.
   Reworded 2026-09-28: the old text also promised that the relay never learns
   contact lists or which devices belong to one person. Routing alone gives both
   away: every device of a person joins the same rooms (its own `inbox:{master}`
   among them) and is reached at the same instant, and two friends' devices share
   a two-person room. Hiding that takes cover traffic or a mixnet, which would
   cost bandwidth and battery and still fall to timing analysis on a small
   network, so the claim now promises what the design can keep: the relay reads
   no data, only routing. WP 3.1 follows at close-out.
