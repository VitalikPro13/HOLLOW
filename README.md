<p align="center">
  <img src="assets/hollow_logo_rounded.png" width="150" alt="Hollow">
</p>

<h1 align="center">Hollow</h1>

<p align="center">
  Distributed, encrypted communication. No central servers or APIs. No accounts.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <img src="https://img.shields.io/badge/platform-Windows%20·%20macOS%20·%20Linux%20·%20Android%20·%20iOS-0078D4" alt="Platform">
  <img src="https://img.shields.io/badge/encryption-end--to--end-blueviolet" alt="Encryption">
  <a href="https://codecov.io/gh/VitalikPro13/HOLLOW" > 
  <img src="https://codecov.io/gh/VitalikPro13/HOLLOW/graph/badge.svg?token=F0TBC256BF" alt="Rust Coverage"></a>
  <img src="https://img.shields.io/badge/status-beta-00BFA6" alt="Status">
</p>

<p align="center">
  <a href="https://sonarcloud.io/summary/overall?id=VitalikPro13_HOLLOW">
  <img src="https://sonarcloud.io/api/project_badges/measure?project=VitalikPro13_HOLLOW&metric=alert_status" alt="Quality Gate"></a>
  <a href="https://sonarcloud.io/summary/overall?id=VitalikPro13_HOLLOW">
  <img src="https://sonarcloud.io/api/project_badges/measure?project=VitalikPro13_HOLLOW&metric=security_rating" alt="Security Rating"></a>
  <a href="https://sonarcloud.io/summary/overall?id=VitalikPro13_HOLLOW">
  <img src="https://sonarcloud.io/api/project_badges/measure?project=VitalikPro13_HOLLOW&metric=reliability_rating" alt="Reliability Rating"></a>
  <a href="https://sonarcloud.io/summary/overall?id=VitalikPro13_HOLLOW">
  <img src="https://sonarcloud.io/api/project_badges/measure?project=VitalikPro13_HOLLOW&metric=sqale_rating" alt="Maintainability Rating"></a>
</p>

<br>

<p align="center">
  <img src="assets/Home_Screenshot_v031.png" width="800" alt="Hollow home screen">
</p>

<details>
<summary><strong>A note from the creator</strong></summary>

<br>

> When I started working on Hollow back in February, I didn't think how large this project would become. It all began with a random thought during school about having a fully peer-to-peer messenger where you're in control of all your data. Then I started planning, researching, locking in the tech stack, and grinding more than full-time to build it.
>
> You can look at the old commits. I tried libp2p that kept failing and then the layout has been rebuilt too. Claude was basically my development tool that always helped me. I might not be the best programmer, but I have engineering thinking and creativity to know what needs to be built and how. Every architecture decision was mine, I traced every bug/performance issue and then we fixed it together, but I'm the one who's in control of what I release. And I'm not planning to publish unusable software that works like total garbage.
>
> As for Hollow, I made it open-source because I want people to have software they can trust, own a copy of, and run themselves. It should be accessible to every regular user who just wants to chat with their friends, with everything working out of the box and have actual privacy/security that's easily verifiable. This is the reason why I adopted modern E2EE protocols and built custom implementations to create the messenger I would want to use myself.
>
> Hollow won't have paywalls. Ever. No matter how much money someone is willing to pay, Hollow will stay open for everybody. Contributors are welcome because we can come together on a single matter that is taken away from us every single day: privacy and ownership. You deserve it. Don't let anybody tell you otherwise.
>
> Thank you for reading, and as always, let's strive for better software together.
>
> -- Vitalii Rovinskyi (AnonListen / VitalikPro13)

</details>

## Overview

Hollow is a fully distributed, end-to-end encrypted communication software. There are no central servers that store your messages or files. Members of a server collectively host it. The relay is a zero-knowledge signaling pipe that forwards encrypted blobs between peers without any ability to read, modify, or store them.

Your identity is a cryptographic keypair. Zero registrations. One recovery phrase or export of your identity into .hollow file, and you own your account forever.

## Features

- **End-to-end encrypted messaging**: Olm (Double Ratchet) for DMs, OpenMLS for servers. Forward secrecy by default
- **Multi-device**: link your phone and desktop into one identity with a short code. Messages, servers, and friends stay in sync end-to-end encrypted across your devices, and a lost device can be revoked remotely at any time
- **Offline delivery without servers**: messages sent while you're away are waiting when you come back. The relay buffers only ciphertext with a short expiry; nothing readable is ever stored anywhere
- **Encrypted voice and video calls**: peer-to-peer WebRTC with SFrame (AES-128-GCM)
- **Voice that sounds right**: on-device noise suppression (RNNoise, with DeepFilterNet3 on desktop), automatic loudness leveling, fullband Opus. No cloud processing ever touches your audio
- **Screen sharing that stays sharp**: a custom-tuned WebRTC engine encodes screens as screen content rather than webcam video, so text stays readable. AV1/VP9, with resolution, framerate and content profiles. Works on all five platforms, both sending and receiving, encrypted with the same SFrame pipeline. Share audio travels on its own encrypted music-grade Opus stream (with per-app capture on Windows and Linux) instead of the voice-call path, so game or music audio arrives crisp instead of call-quality mushy
- **File sharing**: encrypted peer-to-peer transfers. Files up to 34 MB transfer directly. Larger files use Hollow Share (BitTorrent-like swarmed distribution)
- **Distributed storage (Vault)**: erasure-coded encrypted shards distributed across server members. Files survive even when individual peers go offline
- **Servers and channels**: create communities with text channels, voice channels, roles, and permissions. All state synchronized via CRDTs with no authoritative server. Optional: secure Twitch verification to limit members only to your followers/subs
- **Public channels**: you can make a server channel public, so anyone with the server ID or join link can read it without joining. You can use a viewer inside the app or on the [website](https://hollow.anonlisten.com/)
- **Custom relay support**: self-host your own relay for a fully isolated network. One `docker compose up` and you're running
- **Cryptographic identity**: Ed25519 keypair from a BIP-39 mnemonic. No accounts, no passwords, no email or phone verification
- **Full local data retention**: the Archive tab shows every message saved in your local database, and you can export them
- **Verifiable messages**: every message is Ed25519-signed. Exported conversations are cryptographically unforgeable
- **Native TLS**: the relay handles TLS 1.3 directly (no Cloudflare, no reverse proxy). ~572,000 concurrent connections on a single $8/month VPS (see [BENCHMARK.md](relay-uws/BENCHMARK.md))

## Download

| Platform | Links |
|----------|------|
| Windows (10+) | [.exe](https://anonlisten.com/hollow/releases/hollow-0.9.4-win64-setup.exe) / [.zip](https://anonlisten.com/hollow/releases/hollow-0.9.4-win64.zip) |
| macOS (10.15+) | [.dmg](https://anonlisten.com/hollow/releases/hollow-0.9.4.dmg) |
| Linux | [Flatpak](https://anonlisten.com/hollow/releases/hollow-0.9.4-linux-x86_64.flatpak) / [.tar.gz](https://anonlisten.com/hollow/releases/hollow-0.9.4-linux.tar.gz) |
| Android (7+) | [.apk](https://anonlisten.com/hollow/releases/hollow-0.9.4-android.apk) |
| iOS (16+) | [TestFlight](https://testflight.apple.com/join/5YG2S5e8) |
| Web | Not planned |

Current Progress: Tons of changes, all thanks to awesome contributors from the Issues page! Check out the full [changelog.](https://github.com/VitalikPro13/HOLLOW/blob/main/changelog.txt)

## Tech Stack

| Layer | Technology |
|-------|------------|
| UI | Flutter (Dart) on Windows, macOS, Linux, Android, iOS |
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

- [Whitepaper](WHITEPAPER.md): the full protocol specification, covering cryptography, networking, and the threat model
- [Privacy Policy](legal/PRIVACY_POLICY.md): what data exists, where, and what we can access (nothing)
- [Terms of Use](legal/TERMS_OF_USE.md): plain-language terms
- [Relay Documentation](relay-uws/README.md): relay architecture, benchmarks, deployment
- [Mobile Port Plan](MobilePort_Plan.md): Android/iOS build setup, OpenSSL cross-compilation, contributor guide
- [Legality Research](legal/legality.md): age verification, illegal-content/CSAM liability, encryption regulations, legal precedents (US/UK/EU)
- [Transparency Report](legal/transparency_report.md): legal requests received and data disclosure

## Building from Source

### Prerequisites

- Flutter SDK (stable channel)
- Rust toolchain (stable)
- flutter_rust_bridge_codegen v2.11.1

### The custom WebRTC engine

Hollow's desktop builds ship a **patched libwebrtc**: screen shares are encoded
as screen content instead of webcam video (screencast mode + W3C content
hints), which is why text stays sharp instead of turning blocky. The patched
binaries and headers are vendored in git at
`packages/flutter_webrtc/third_party/libwebrtc/`, so a normal clone + build
just works, with no downloads and no extra steps. Rebuilding libwebrtc itself is only
needed for maintainers bumping the upstream milestone; the full reproducible
recipe (source pins, patch file, gn args) lives in
[BUILDING.md](packages/flutter_webrtc/third_party/libwebrtc/BUILDING.md).

### Build (Windows)

Two native binaries are bundled with the Windows build. If they're missing,
CMake prints a warning (`vendor/ffmpeg/ffmpeg-win-x64.exe not found...` /
`screen_audio_test.exe not found...`) and the build still succeeds, but video
thumbnails and screen-share audio are disabled at runtime. Fetch/build them
once before your first release build:

```powershell
# 1. Fetch the vendored ffmpeg (video thumbnails)
pwsh scripts\fetch_ffmpeg.ps1

# 2. Build the screen audio capturer (screen-share system audio)
pwsh scripts\build_screen_audio.ps1
```

Then build the app:

```bash
# Generate FFI bindings (only needed after changing Rust API signatures)
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"

# Run on Windows (debug)
flutter run -d windows

# Build release
flutter build windows
```

<details>
<summary><strong>macOS build instructions</strong></summary>

Install Rust (if not already installed):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
```

Install the build tools (Xcode from the App Store, plus CocoaPods):

```bash
xcode-select --install        # if not already present
sudo gem install cocoapods     # or: brew install cocoapods
```

Build the screen audio capturer **before** building the app (it's bundled into
the `.app` during the Xcode build phase). Screen-share audio is unavailable
without it:

```bash
bash scripts/build_screen_audio.sh
```

Then build:

```bash
flutter pub get
cd macos
flutter build macos --release
```

The output is at `build/macos/Build/Products/Release/Hollow.app` (a universal
x86_64 + arm64 bundle).

> **Note:** Hollow runs on macOS 10.15 and later. Screen-share audio capture and
> call recording require macOS 13.0+ (Apple exposes no system-audio API below
> that); everything else, including screen-share video, works on 10.15.

</details>

<details>
<summary><strong>Linux build instructions</strong></summary>

Install Rust (if not already installed):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
```

Install system dependencies (Ubuntu/Debian):

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libssl-dev libnotify-dev libayatana-appindicator3-dev libpulse-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly lld curl build-essential
```

Then build:

```bash
flutter pub get
flutter build linux
```

The output binary is at `build/linux/x64/release/bundle/hollow`.

</details>

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, coding conventions, and how to submit a pull request.

- Report bugs and request features via [Issues](../../issues)
- Read the [Whitepaper](WHITEPAPER.md) for protocol-level context
- Report security vulnerabilities privately: see [SECURITY.md](SECURITY.md)

## License

Copyright (C) 2025-2026 Vitalii Rovinskyi <vitaliy2007rova@gmail.com>

The Hollow client and core library are licensed under the [GNU Affero General Public License v3.0](LICENSE). The relay server ([relay-uws/](relay-uws/)) is licensed under the [MIT License](relay-uws/LICENSE).

For commercial use without AGPL obligations, a commercial license is available:

| | AGPL-3.0 (free) | Commercial |
|---|---|---|
| Personal and community use | Yes | n/a |
| Modify and distribute | Yes (source must stay open) | Yes (proprietary OK) |
| Small business | n/a | $1,000/year |
| Enterprise (SSO, SLA, custom) | n/a | [Contact us](mailto:collab@anonlisten.com) |

The Hollow name, logo, and branding are trademarks of AnonListen and are not covered by the open-source license.

## Support the Project

Hollow is funded by the community, not by selling your data. Every support is appreciated!

- [Ko-fi](https://ko-fi.com/anonlisten)
- [Patreon](https://patreon.com/anonlisten)
