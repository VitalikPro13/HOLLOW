<p align="center">
  <img src="assets/hollow_logo_rounded.png" width="150" alt="Hollow">
</p>

<h1 align="center">Hollow</h1>

<p align="center">
  Distributed, encrypted communication. No central servers or APIs. No accounts. No compromise.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <img src="https://img.shields.io/badge/platform-Windows%20·%20macOS%20·%20Linux%20·%20Android-0078D4" alt="Platform">
  <img src="https://img.shields.io/badge/encryption-end--to--end-blueviolet" alt="Encryption">
  <a href="https://codecov.io/gh/VitalikPro13/HOLLOW" > 
  <img src="https://codecov.io/gh/VitalikPro13/HOLLOW/graph/badge.svg?token=F0TBC256BF" alt="Rust Coverage"></a>
  <img src="https://img.shields.io/badge/status-alpha-orange" alt="Status">
</p>

<br>

<p align="center">
  <img src="assets/Home_Screenshot_v031.png" width="800" alt="Hollow — Home">
</p>

> When I started working on Hollow back in February, I didn't think how large this project would become. It all began with a random thought during school about having a fully peer-to-peer messenger where you're in control of all your data. Then I started planning, researching, locking in the tech stack, and grinding more than full-time to build it.
>
> You can look at the old commits. I tried libp2p that kept failing and then the layout has been rebuilt too. Claude was basically my development tool that always helped me. I might not be the best programmer, but I have engineering thinking and creativity to know what needs to be built and how. Every architecture decision was mine, I traced every bug/performance issue and then we fixed it together, but I'm the one who's in control of what I release. And I'm not planning to publish unusable software that works like total garbage.
>
> As for Hollow, I made it open-source because I want people to have software they can trust, own a copy of, and run themselves. It should be accessible to every regular user who just wants to chat with their friends, with everything working out of the box and have actual privacy/security that's easily verifiable. This is the reason why I adopted modern E2EE protocols and built custom implementations to create the messenger I would want to use myself.
>
> Hollow won't have paywalls. Ever. No matter how much money someone is willing to pay, Hollow will stay open for everybody. Contributors are welcome because we can come together on a single matter that is taken away from us every single day - privacy and ownership. You deserve it. Don't let anybody tell you otherwise.
>
> Thank you for reading, and as always, let's strive for better software together.
>
> -- AnonListen

## Overview

Hollow is a fully distributed, end-to-end encrypted communication platform. There are no central servers that store your messages or files. Members of a server collectively host it. The relay is a zero-knowledge signaling pipe that forwards encrypted blobs between peers without any ability to read, modify, or store them.

Your identity is a cryptographic keypair. Zero registrations. One recovery phrase or export of your identity into .hollow file, and you own your account forever.

## Features

- **End-to-end encrypted messaging** -- Olm (Double Ratchet) for DMs, OpenMLS for servers. Forward secrecy by default
- **Encrypted voice and video calls** -- peer-to-peer WebRTC with SFrame (AES-128-GCM)
- **Screen sharing** -- with system audio capture (Windows & macOS), encrypted with the same SFrame pipeline
- **File sharing** -- encrypted peer-to-peer transfers. Files up to 34 MB transfer directly. Larger files automatically use Hollow Share (BitTorrent-like swarmed distribution)
- **Distributed storage (Vault)** -- erasure-coded encrypted shards distributed across server members. Files survive even when individual peers go offline
- **Servers and channels** -- create communities with text channels, voice channels, roles, and permissions. All state synchronized via CRDTs with no authoritative server. Optional: secure Twitch verification to limit members only to your followers/subs
- **Public channels** -- you can make your server channel public, so users can easily read it just from knowing the server ID/join link and without the need to even join it. You can use a viewer inside the app or on the [website](https://hollow.anonlisten.com/)
- **Custom relay support** -- self-host your own relay for a fully isolated network. One `docker compose up` and you're running
- **Cryptographic identity** -- Ed25519 keypair from a BIP-39 mnemonic. No accounts, no passwords, no email or phone verification
- **Full local data retention** -- using the Archive tab, you can see all the messages saved in your local database that you can easily export
- **Verifiable messages** -- every message is Ed25519-signed. Exported conversations are cryptographically unforgeable
- **Native TLS** -- the relay handles TLS 1.3 directly (no Cloudflare, no reverse proxy). ~572,000 concurrent connections on a single $8/month VPS (see [BENCHMARK.md](relay-uws/BENCHMARK.md))

## Download

| Platform | Link |
|----------|------|
| Windows (10+) | [Download (.zip)](https://hollow.anonlisten.com) |
| macOS (14.2+) | [Download (.dmg)](https://hollow.anonlisten.com) |
| Linux | [Download (Experimental Flatpak)](https://hollow.anonlisten.com) |
| Android (7+) | [Download (Experimental APK)](https://hollow.anonlisten.com) |
| iOS | Coming soon |
| Web | Not planned |

Current Progress: macOS is fully working! Linux is experimental and not properly tested but core features work. Mobile port to Android/iOS is FINALLY DONE! 100% of the features are implemented, including the push notifications support (iOS is in the process). Websites are updated, so now you can enjoy the proper cross-platform release. There are areas for improvement, but everything will come in its time!

## Tech Stack

| Layer | Technology |
|-------|------------|
| UI | Flutter (Dart) -- Windows, macOS, Linux, Android, iOS |
| Backend | Rust via flutter_rust_bridge FFI |
| DM Encryption | vodozemac (Olm / Double Ratchet) |
| Server Encryption | OpenMLS 0.8 |
| Media Encryption | SFrame (AES-128-GCM) |
| Voice/Video | WebRTC (peer-to-peer) |
| Local Storage | SQLCipher (encrypted SQLite) |
| Identity | Ed25519 (BIP-39 mnemonic) |
| Relay | uWebSockets C++ (13.4 KB/conn, native TLS) |

## Self-Hosting

Hollow supports self-hosted relays for fully isolated networks, so only connected users in it can communicate between each other without the official network.

```bash
cd relay-uws
cp .env.example .env              # set your domain, IP, TURN secret
cp turnserver.conf.example turnserver.conf
docker compose up -d
```

In the Hollow app, enter your relay domain during setup or in Settings. See [relay-uws/README.md](relay-uws/README.md) for full documentation.

## Documentation

- [Whitepaper](WHITEPAPER.md) -- full protocol specification: cryptography, networking, threat model
- [Privacy Policy](legal/PRIVACY_POLICY.md) -- what data exists, where, and what we can access (nothing)
- [Terms of Use](legal/TERMS_OF_USE.md) -- plain-language terms
- [Relay Documentation](relay-uws/README.md) -- relay architecture, benchmarks, deployment
- [Mobile Port Plan](MobilePort_Plan.md) -- Android/iOS build setup, OpenSSL cross-compilation, contributor guide
- [Legality Research](legal/legality.md) -- age verification laws, encryption regulations, legal precedents (US/UK/EU)
- [Transparency Report](legal/transparency_report.md) -- legal requests received and data disclosure

## Building from Source

### Prerequisites

- Flutter SDK (stable channel)
- Rust toolchain (stable)
- flutter_rust_bridge_codegen v2.11.1

### Build

```bash
# Generate FFI bindings (only needed after changing Rust API signatures)
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"

# Run on Windows (debug)
flutter run -d windows

# Build release
flutter build windows
```

<details>
<summary><strong>Linux build instructions</strong></summary>

Install Rust (if not already installed):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
```

Install system dependencies (Ubuntu/Debian):

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libssl-dev libnotify-dev libayatana-appindicator3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly lld curl build-essential
```

Then build:

```bash
flutter pub get
flutter build linux
```

The output binary is at `build/linux/x64/release/bundle/hollow`.

> **Note:** Linux desktop support is experimental. The app builds and core features work. Needs testing.

</details>

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, coding conventions, and how to submit a pull request.

- Report bugs and request features via [Issues](../../issues)
- Read the [Whitepaper](WHITEPAPER.md) for protocol-level context
- Report security vulnerabilities privately -- see [SECURITY.md](SECURITY.md)

## License

Copyright (C) 2025-2026 Vitalii Rovinskyi <vitaliy2007rova@gmail.com>

The Hollow client and core library are licensed under the [GNU Affero General Public License v3.0](LICENSE). The relay server ([relay-uws/](relay-uws/)) is licensed under the [MIT License](relay-uws/LICENSE).

For commercial use without AGPL obligations, a commercial license is available:

| | AGPL-3.0 (free) | Commercial |
|---|---|---|
| Personal and community use | Yes | -- |
| Modify and distribute | Yes (source must stay open) | Yes (proprietary OK) |
| Small business | -- | $1,000/year |
| Enterprise (SSO, SLA, custom) | -- | [Contact us](mailto:collab@anonlisten.com) |

The Hollow name, logo, and branding are trademarks of AnonListen and are not covered by the open-source license.

## Support the Project

Hollow is funded by the community, not by selling your data. Every support is appreciated!

- [Ko-fi](https://ko-fi.com/anonlisten)
- [Patreon](https://patreon.com/anonlisten)
