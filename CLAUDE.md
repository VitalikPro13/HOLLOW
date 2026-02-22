# HAVEN — Project Instructions for Claude Code

## What Is This
Haven is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HAVEN_PLAN.md` for the full architecture.

## Tech Stack
- **UI:** Flutter (Dart) — all platforms (Windows, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` FFI
- **Org ID:** com.anonlisten
- **Project name:** haven

## Project Structure
```
HAVEN/
├── lib/                  # Dart/Flutter code (UI, app logic, state management)
├── rust/                 # Rust workspace (networking, crypto, storage, CRDTs)
├── test/                 # Flutter/Dart tests
├── android/              # Android platform files
├── ios/                  # iOS platform files
├── windows/              # Windows platform files
├── macos/                # macOS platform files
├── linux/                # Linux platform files
├── web/                  # Web platform files
├── HAVEN_PLAN.md         # Full architecture & design document
└── CLAUDE.md             # This file
```

## Build & Run Commands
```bash
# Run on current platform (debug)
flutter run

# Run on specific platform
flutter run -d windows
flutter run -d chrome
flutter run -d android

# Build release
flutter build windows
flutter build apk
flutter build web

# Run tests
flutter test

# Analyze code
flutter analyze
```

## Current Phase
**Phase 1: Foundation** — Two users chat on LAN with E2EE.

### Next milestone: FFI Bridge
Get `flutter_rust_bridge` working with a trivial Dart → Rust → Dart round-trip.

## Coding Conventions
- Dart: follow standard `flutter_lints` / `analysis_options.yaml`
- Rust: follow standard `cargo clippy` recommendations
- File naming: snake_case for Dart and Rust files
- No Electron, no Node.js, no web frameworks — Flutter only for UI

## Rules
- Never commit secrets, keys, or credentials
- Rust handles: networking (libp2p), crypto (libsodium/Signal/MLS), CRDTs (Automerge), storage engine
- Dart handles: UI, app logic, state management
- All crypto operations must use constant-time implementations
- Ask before making architectural decisions not covered in HAVEN_PLAN.md
