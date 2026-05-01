# Hollow — Privacy Policy

**Last updated: May 1, 2026**

Hollow is built on one principle: your conversations are yours. We cannot read your messages, listen to your calls, or identify you. This policy explains exactly what data exists, where it exists, and what we can and cannot access.

## The short version

- We **cannot** read your messages or files — everything is end-to-end encrypted.
- We **do not** collect analytics, telemetry, or usage data. (The relay tracks an aggregate online user count in memory for display purposes — this is a single number, not per-user, and is lost on restart.)
- We **do not** require an email, phone number, or any real identity to create an account.
- We **do not** store messages on any server — the relay is a stateless forwarder.
- We **do not** sell, rent, or monetize your data in any way.

## How Hollow works

Hollow is a fully distributed, encrypted communication platform. There is no central server that stores your data. Instead:

- **Your identity** is a cryptographic keypair (Ed25519) generated on your device from a BIP-39 mnemonic phrase. We never see or store this keypair.
- **Messages** are end-to-end encrypted using the Olm/Double Ratchet protocol (for direct messages) and OpenMLS (for group/server channels). Only the intended recipients can decrypt them.
- **Voice and video calls** are peer-to-peer (WebRTC) with SFrame encryption (AES-128-GCM). Call content never passes through our infrastructure in a readable form.
- **Files** are encrypted and transferred peer-to-peer. In smaller communities (under 6 members) and direct messages, files are fully replicated to all participants. In larger communities, files use an erasure-coded shard system where encrypted fragments are distributed across peers — no single peer (including us) holds a complete file.
- **All local data** is stored in an encrypted database (SQLCipher) on your device.

## What the relay server does

Hollow uses a WebSocket relay server for signaling and message routing. The relay is a **stateless forwarder** — it passes encrypted data between connected peers and retains nothing after delivery.

**What the relay processes in transit (not stored):**

- Encrypted message payloads (opaque binary blobs — the relay cannot decrypt them)
- Cryptographic peer IDs (not tied to any real-world identity)
- Room membership for active connections (held in memory only, lost on restart)

**What the relay does NOT have access to:**

- Message content, file content, or call content
- Your IP address in application logs (the relay does not log IP addresses)
- Your real name, email, phone number, or any identifying information
- Which servers you are a member of or who you communicate with (room identifiers are opaque hashes)
- Any historical data — the relay holds no persistent storage of user activity

## TURN relay server

For voice and video calls where a direct peer-to-peer connection cannot be established (e.g., due to restrictive network configurations), encrypted media may be relayed through a TURN server. The TURN server handles only encrypted data and cannot decrypt call content. The TURN server is configured with logging disabled — no session metadata, IP addresses, or bandwidth data is recorded.

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

## Law enforcement and government requests

We are committed to transparency about any requests we receive.

Because Hollow is designed with privacy by design, our ability to respond to data requests is inherently limited:

- We **cannot** provide message content — we do not have encryption keys and messages are not stored on our servers.
- We **cannot** identify users — accounts are cryptographic keypairs with no link to real-world identity.
- We **cannot** provide conversation history — no message history exists on our infrastructure.
- We **cannot** provide metadata about who communicates with whom — the relay does not maintain or log this information persistently.

We will comply with valid, binding court orders issued under applicable law (EU/French jurisdiction). We will notify affected users of any requests unless legally prohibited from doing so. We will challenge overbroad or legally questionable requests.

We publish a transparency report documenting any government or law enforcement requests received.

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

Hollow does not integrate with any analytics, advertising, or tracking services. Hollow is a native desktop and mobile — it does not use cookies or any web-based tracking technology.

If you download Hollow from a third-party platform (e.g., GitHub), that platform's own privacy policy governs your interaction with their service.

## Children's privacy

Hollow does not knowingly collect information from children under the age of 13. Since Hollow does not collect personal information from any user, there is no age-specific data collection to address. Users must be at least 13 years old (or the applicable age of majority in their jurisdiction) to use Hollow, as outlined in our Terms of Use.

## Changes to this policy

We may update this privacy policy from time to time. Changes will be posted with an updated "Last updated" date. Material changes will be communicated through the application. Your continued use of Hollow after changes constitutes acceptance of the updated policy.

## Contact

If you have questions about this privacy policy or Hollow's privacy practices:

- **Email:** privacy@anonlisten.com
- **Website:** [anonlisten.com](https://anonlisten.com)
