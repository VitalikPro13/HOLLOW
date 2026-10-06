# Building Hollow

Hollow is a Flutter app (Dart, `lib/`) on top of a Rust core (`rust/hollow_core/`), joined by flutter_rust_bridge. You don't build the Rust core separately. Cargokit compiles it inside every `flutter run` and `flutter build`, and it installs the Rust targets it needs through rustup on the first build.

Run every command below from the repository root.

## Every platform

- Flutter SDK, stable channel. We build with 3.47.0.
- Rust toolchain, stable, through [rustup](https://rustup.rs).
- flutter_rust_bridge_codegen 2.11.1, only if you change the Rust API.

The generated bindings in `lib/src/rust/` are committed, so a fresh clone builds without codegen. After changing anything in `rust/hollow_core/src/api/`, regenerate them:

```bash
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"
```

The app doesn't need git submodules. Only the relay does (`relay-uws/`).

### The patched WebRTC

Desktop builds ship a patched libwebrtc that encodes screen shares as screen content instead of webcam video, which is why text stays sharp. The patched binaries and headers are vendored at `packages/flutter_webrtc/third_party/libwebrtc/`, so a normal clone builds with no extra downloads. Only maintainers bumping the upstream milestone need to rebuild it, and [BUILDING.md](packages/flutter_webrtc/third_party/libwebrtc/BUILDING.md) in that folder has the reproducible recipe.

## Windows

You need:

- Visual Studio 2022 with the "Desktop development with C++" workload.
- OpenSSL 3, 64-bit, installed at `C:\Program Files\OpenSSL-Win64` (the Win64 OpenSSL installer from slproweb.com puts it there). SQLCipher links against it, and the build copies `libcrypto-3-x64.dll` and `libssl-3-x64.dll` from that exact path next to `hollow.exe`. Point the Rust build at it with three system variables:

  ```powershell
  # In an elevated PowerShell, then open a new terminal
  setx /M OPENSSL_DIR "C:\Program Files\OpenSSL-Win64"
  setx /M OPENSSL_LIB_DIR "C:\Program Files\OpenSSL-Win64\lib\VC\x64\MD"
  setx /M OPENSSL_INCLUDE_DIR "C:\Program Files\OpenSSL-Win64\include"
  ```

- NASM. The `webcrypto` package builds BoringSSL with CMake before any Hollow code compiles, and BoringSSL's assembly needs it.

If Strawberry Perl is installed, its `cmake` and `ninja` sit ahead of Visual Studio's on `PATH` and that BoringSSL step fails with `CMAKE_C_COMPILER not set`. Run Flutter through `scripts\flutter_win.ps1` instead. It fixes `PATH` for that one process and borrows Strawberry's `nasm.exe`. It expects Visual Studio 2022 Community in its default location.

```powershell
powershell -File scripts\flutter_win.ps1 run -d windows
```

Two native helpers ship next to the app. Without them the build still succeeds, but video thumbnails and screen-share audio are off. Fetch and build them once:

```powershell
pwsh scripts\fetch_ffmpeg.ps1        # ffmpeg, for video thumbnails
pwsh scripts\build_screen_audio.ps1  # screen-share system audio
```

Then:

```bash
flutter run -d windows        # debug
flutter build windows         # release
```

## macOS

Install Xcode from the App Store, the command line tools and CocoaPods:

```bash
xcode-select --install
sudo gem install cocoapods     # or: brew install cocoapods
```

Build the screen audio capturer first. The Xcode build only copies it into the app, and without it screen-share audio is off:

```bash
bash scripts/build_screen_audio.sh
```

Then:

```bash
flutter pub get
flutter build macos --release
```

The app lands in `build/macos/Build/Products/Release/Hollow.app`, a universal x86_64 and arm64 bundle. It runs on macOS 12 and later. Screen-share audio and call recording need macOS 13, because Apple has no system-audio API below it.

For a signed build, copy `macos/Flutter/LocalSigning.xcconfig.example` to `LocalSigning.xcconfig` and put your Team ID in it. That file is gitignored. Without it the project still builds for local use, with no team.

## Linux

On Ubuntu or Debian:

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libssl-dev libnotify-dev libayatana-appindicator3-dev libpulse-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly lld curl build-essential
flutter pub get
flutter build linux
```

The binary lands in `build/linux/x64/release/bundle/hollow`. For screen-share audio, run `bash scripts/build_screen_audio.sh` before `flutter build linux`.

## Android

You need the Android SDK with NDK 28.2.13676358, the version Flutter 3.47 asks for. Install it from Android Studio's SDK Manager under SDK Tools, with "Show Package Details" ticked.

### OpenSSL for SQLCipher

The NDK has no OpenSSL, and SQLCipher needs it. Static OpenSSL 3.5.8 libraries for every ABI are committed in `rust/hollow_core/.cargo/android-openssl-headers/`, and the README there explains how they were built. The build finds them through system environment variables, because cargokit never reads `rust/hollow_core/.cargo/config.toml`.

On Windows, from the repository root in an elevated PowerShell:

```powershell
$ssl = "$PWD\rust\hollow_core\.cargo\android-openssl-headers"
setx /M HOLLOW_ANDROID_OPENSSL_INCLUDE "$ssl\include"
setx /M HOLLOW_ANDROID_OPENSSL_LIB "$ssl\lib"
$abis = @{ AARCH64_LINUX_ANDROID = 'aarch64'; ARMV7_LINUX_ANDROIDEABI = 'armv7';
           X86_64_LINUX_ANDROID = 'x86_64'; I686_LINUX_ANDROID = 'i686' }
foreach ($t in $abis.Keys) {
    setx /M "${t}_OPENSSL_INCLUDE_DIR" "$ssl\include"
    setx /M "${t}_OPENSSL_LIB_DIR" "$ssl\lib\$($abis[$t])"
    setx /M "${t}_OPENSSL_STATIC" 1
}
```

Open a new terminal afterwards. On Linux or macOS, export the same variables from your shell profile.

### Firebase

The Android build applies the Google Services plugin, so it fails until `android/app/google-services.json` exists. That file is gitignored. Create a Firebase project, add an Android app with the package name `com.anonlisten.hollow`, and save its `google-services.json` there. With your own project the app builds and runs. Only push notifications from the official relay won't reach it, since they go through Hollow's Firebase project.

### Build

```bash
flutter devices                    # list emulators and phones
flutter run -d <device-id>         # debug
flutter build apk --release        # one APK for every ABI, as releases ship
```

If the Rust build fails, `flutter build apk` can still report success and package the `libhollow_core.so` left over from the previous build. Check the output for `error occurred in cc-rs` or `warning: build failed` before trusting an APK.

## iOS

iOS builds need a Mac with Xcode and CocoaPods. No OpenSSL is involved, because on Apple platforms SQLCipher uses CommonCrypto.

- The Xcode project expects `ios/Runner/GoogleService-Info.plist`, which is gitignored. Add one from your Firebase project (an iOS app with the bundle ID `com.anonlisten.hollow`), or the build stops on the missing file.
- Copy `ios/Flutter/LocalSigning.xcconfig.example` to `LocalSigning.xcconfig`. Fill in your Team ID only for a real device or TestFlight. The Simulator needs none.
- On an Apple Silicon Mac, add these two lines to that same `LocalSigning.xcconfig`. Otherwise BoringSSL fails to link the x86_64 Simulator slice, which nothing on that Mac would run anyway:

  ```
  EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64
  ONLY_ACTIVE_ARCH = YES
  ```

Then build for the Simulator:

```bash
flutter build ios --simulator --debug
```

Device and TestFlight builds go through Xcode. Open `ios/Runner.xcworkspace` and use Product > Archive. The notification service extension links the Rust core through CocoaPods, so there's nothing to wire up by hand. The project targets iOS 15.0, while TestFlight builds need iOS 16.
