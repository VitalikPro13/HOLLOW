# Hollow — Privacy Policy

**Last updated: July 10, 2026**

Hollow is built on one principle: your conversations are yours. We cannot read your messages, listen to your calls, or identify you. This policy explains exactly what data exists, where it exists, and what we can and cannot access.

## The short version

- We **cannot** read your messages or files — everything is end-to-end encrypted.
- We **do not** collect analytics, telemetry, or usage data. (The relay tracks an aggregate online user count in memory for display purposes — this is a single number, not per-user, and is lost on restart.)
- We **do not** require an email, phone number, or any real identity to create an account.
- We **do not** store your messages on disk on any server. To deliver messages sent while you are offline, the relay can hold end-to-end encrypted payloads in memory for a limited time (3 days by default, adjustable) — it cannot read them, and they are deleted on delivery or expiry.
- We **do not** sell, rent, or monetize your data in any way.

## How Hollow works

Hollow is a fully distributed, encrypted communication platform. There is no central server that stores your data. Instead:

- **Your identity** is a cryptographic keypair (Ed25519) generated on your device from a BIP-39 mnemonic phrase. We never see or store this keypair.
- **Messages** are end-to-end encrypted using the Olm/Double Ratchet protocol (for direct messages) and OpenMLS (for group/server channels). Only the intended recipients can decrypt them.
- **Voice and video calls** are peer-to-peer (WebRTC) with SFrame encryption (AES-128-GCM). Call content never passes through our infrastructure in a readable form.
- **Files** are encrypted and transferred peer-to-peer. In smaller communities (under 6 members) and direct messages, files are fully replicated to all participants. In larger communities, files use an erasure-coded shard system where encrypted fragments are distributed across peers — no single peer (including us) holds a complete file.
- **All local data** is stored in an encrypted database (SQLCipher) on your device.

## What the relay server does

Hollow uses a WebSocket relay server for signaling and message routing. The relay routes end-to-end encrypted data between peers — it cannot decrypt anything it carries, and it writes nothing about you or your activity to disk. The only thing the relay ever persists is the anonymous abuse-report counter described in "In-app reporting and blocking" below.

**What the relay processes in transit (not stored):**

- Encrypted message payloads (opaque binary blobs — the relay cannot decrypt them)
- Cryptographic peer IDs (not tied to any real-world identity)
- Room membership for active connections (held in memory only, lost on restart)
- Temporary display nicknames, if you claim one (held in memory only, released when you disconnect)

**Offline delivery (in-memory, encrypted).** To deliver messages sent while you are offline, the relay can hold end-to-end encrypted payloads in memory for a limited time — 3 days by default. You can adjust or disable this for your own messages in Settings, and server owners can disable it for their channels. These buffers contain only ciphertext the relay cannot read, are subject to small volume caps, are deleted on delivery or expiry, are never written to disk, and are lost if the relay restarts. The buffer is a convenience, not a requirement — if the relay never held a message, you still receive it directly from your peers when you are both online.

**Fair-use accounting (in-memory).** To keep the relay usable for everyone, it keeps per-IP-address counters in memory: the number of simultaneous connections and the amount of data relayed per day (see the Terms of Use for the current limits). These counters exist only in memory, are never written to disk or to logs, reset daily, and are lost on restart.

**Push notification tokens (mobile).** If you use Hollow on Android or iOS, the relay holds your device's push token in memory only (never on disk) so it can send a wake signal when a message arrives while the app is closed. See "Push notifications (mobile)" below.

**What the relay does NOT have access to:**

- Message content, file content, or call content
- Your IP address in application logs (the relay does not log IP addresses — they are used only transiently in memory for the fair-use counters above)
- Your real name, email, phone number, or any identifying information
- Which servers you are a member of or who you communicate with (room identifiers are opaque hashes)
- Any historical data — apart from the temporary encrypted offline-delivery buffers above, the relay retains nothing after delivery, and no record of user activity is ever written to disk

## TURN relay server

For voice and video calls where a direct peer-to-peer connection cannot be established (e.g., due to restrictive network configurations), encrypted media may be relayed through a TURN server. The TURN server handles only encrypted data and cannot decrypt call content. The TURN server is configured with logging disabled — no session metadata, IP addresses, or bandwidth data is recorded.

## Push notifications (mobile)

On Android and iOS, Hollow uses Firebase Cloud Messaging (Google) and the Apple Push Notification service to wake the app when a message arrives while it is closed. What this means for your data:

- Push payloads **never contain message content** — only an opaque wake signal and cryptographic peer IDs. The actual message is fetched in encrypted form and decrypted on your device.
- Google and Apple can see that your device received a push notification and when, but never what a message says or who anyone is in any real-world sense.
- The relay holds your device's push token in memory only; it is never written to disk.

Desktop platforms do not use any push service. Notifications on desktop are generated entirely locally.

## In-app reporting and blocking

- **Blocking** is entirely local. Your block list is stored only on your device in the encrypted database — it is never sent to us and we cannot see it.
- **Reporting** a user sends the reported account's cryptographic peer ID and a category (e.g., spam, harassment) to the relay. The relay stores only anonymous aggregates: a count of reports per reported account and category, plus a one-way hash used to prevent duplicate reports. Who reported whom is never written to disk, and no message content is (or can be) included in a report — we cannot decrypt any conversation.

## Infrastructure and hosting

Our relay infrastructure is hosted by OVHcloud SAS (France), subject to EU jurisdiction and GDPR. OVH operates our servers as opaque workloads — they do not inspect, analyze, or store the content passing through them.

**What our hosting provider can see:**

- That a server process is running on the VPS
- Network traffic volume (but not content — all traffic is TLS-encrypted)
- Standard VPS operational metrics (CPU, memory usage)

**What our hosting provider cannot see:**

- Message content (end-to-end encrypted before reaching the relay)
- User identities (cryptographic peer IDs have no link to real identities)
- Conversation metadata (which users talk to which other users)

## Twitch integration (optional)

If a server owner enables Twitch verification, members who choose to verify will complete a standard OAuth flow with Twitch. During this process:

- Hollow temporarily receives an OAuth access token to verify your Twitch follow/subscription status.
- This token is used once for verification and is not stored by Hollow's infrastructure.
- The server owner's Twitch channel name and your verification status are stored locally on your device.
- We do not store any Twitch data on our servers.

Your use of Twitch is governed by [Twitch's own privacy policy](https://www.twitch.tv/p/en/legal/privacy-policy/).

## Game showcase (optional)

If you add game cards to your profile showcase, your game search queries are sent through our web server to the IGDB game database (operated by Twitch) and, for some games, Steam's public store data, to fetch game details and artwork. Your device never contacts IGDB or Steam directly, and these lookups happen only while you are editing your own profile. Search terms travel in the request body rather than the URL, so they do not appear in standard web-server access logs, and the request carries no Hollow identity — a search can never be linked to your account. Our server keeps an anonymous cache of game data and search terms (never who searched, or from where) so repeated searches don't reach IGDB at all. The resulting artwork is embedded into your encrypted profile data — people who view your profile never contact IGDB, Steam, or our web server.

## Law enforcement and government requests

We are committed to transparency about any requests we receive.

Because Hollow is designed with privacy by design, our ability to respond to data requests is inherently limited:

- We **cannot** provide message content — we do not have encryption keys and messages are not stored on our servers.
- We **cannot** identify users — accounts are cryptographic keypairs with no link to real-world identity.
- We **cannot** provide conversation history — no readable message history exists on our infrastructure. The temporary offline-delivery buffer holds only end-to-end encrypted payloads, in memory, that we have no keys to decrypt.
- We **cannot** provide metadata about who communicates with whom — the relay does not maintain or log this information persistently.

The only user-related record our infrastructure writes to disk is the anonymous abuse-report counter described above, which contains no identities, no message content, and no communication metadata.

We will comply with valid, binding court orders issued under applicable law (EU/French jurisdiction). We will notify affected users of any requests unless legally prohibited from doing so. We will challenge overbroad or legally questionable requests.

If we receive any government or law enforcement requests, we will publish a transparency report documenting them.

## Data stored on your device

Hollow stores the following data locally on your device in an encrypted database:

- Your cryptographic identity (keypair, mnemonic-derived)
- Your profile information (display name, avatar, status — all optional)
- Message history for your conversations
- Encryption keys for your active sessions
- Server membership and channel data
- Downloaded files and media

This data never leaves your device in an unencrypted form. If you delete the Hollow application, this data is removed from your device.

## Third-party services

Hollow does not integrate with any analytics, advertising, or tracking services. Hollow is a native desktop and mobile application — it does not use cookies or any web-based tracking technology.

The only third parties Hollow ever communicates with are the ones described in this policy: Google/Apple push services on mobile (wake signals only, no content), and — only if you choose to use the corresponding optional features — Twitch (verification) and IGDB/Steam via our proxy (game showcase).

If you download Hollow from a third-party platform (e.g., GitHub), that platform's own privacy policy governs your interaction with their service.

## Children's privacy

Hollow does not knowingly collect information from children under the age of 13. Since Hollow does not collect personal information from any user, there is no age-specific data collection to address. Users must be at least 13 years old (or the applicable age of majority in their jurisdiction) to use Hollow, as outlined in our Terms of Use.

## Changes to this policy

We may update this privacy policy from time to time. Changes will be posted with an updated "Last updated" date. Material changes will be communicated through the application. Your continued use of Hollow after changes constitutes acceptance of the updated policy.

## Contact

If you have questions about this privacy policy or Hollow's privacy practices:

- **Email:** privacy@anonlisten.com
- **Website:** [anonlisten.com](https://anonlisten.com)
