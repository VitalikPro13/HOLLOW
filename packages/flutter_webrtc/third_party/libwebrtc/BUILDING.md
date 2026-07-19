# Building Hollow's Custom libwebrtc

Hollow does **not** use stock webrtc-sdk prebuilt binaries on Windows/Linux
desktop. The `libwebrtc.dll` / `libwebrtc.so` in `lib/` (and the headers in
`include/`) are a **custom build** carrying Hollow patches, and they are
**committed to git** — a normal `flutter build` never needs anything from this
document. Read on only if you need to *rebuild* libwebrtc itself (new upstream
milestone, new wrapper patch, new architecture).

Both binaries were built 2026-07-19 from the same pinned sources: Windows on
the maintainer machine (`D:\libwebrtc-build`), Linux on the build VM
(`~/libwebrtc-build`) — both trees remain warm for incremental rebuilds.

## What the custom build changes

Two patch files in this folder, BOTH required:

**[`hollow-core-audio.patch`](hollow-core-audio.patch)** — small interface
additions to the WebRTC core (`AudioTransport::UpdateAudioSenders` /
`SetStereoChannelSwapping` virtuals + AudioState/voice-engine plumbing, ~77
lines across 13 files). The wrapper branch's `custom_audio_transport_impl.h`
does not compile against a pristine core without it; the shipped Windows DLL
contains these changes, so all platforms must apply them for parity.

**[`hollow-screencast.patch`](hollow-screencast.patch)** — the wrapper patch:

1. **`ScreenCapturerTrackSource::is_screencast()` returns `true`**
   (`src/internal/desktop_capturer.h`). Without it, desktop screen shares
   encode as *camera* video: denoising on, the QP quality scaler silently
   downscaling resolution, and none of the codecs' screen-content modes (VP8
   screen mode, VP9 screen tune, AV1 palette) active — the historical "blocky
   text" screen share. macOS/iOS/Android set this flag natively; the patch
   brings the Windows/Linux wrapper in line.
2. **`RTCVideoTrack::SetContentHint(kNone|kFluid|kDetailed|kText)`**
   (`include/rtc_video_track.h` + impl). Exposes the W3C contentHint so the
   app can switch text/motion encoding profiles at runtime. Reached from Dart
   via `Helper.setVideoContentHint` → plugin method `videoTrackSetContentHint`.

Related but *not* in the binary: the flutter_webrtc plugin's
`updateRtpParameters` (`common/cpp/src/flutter_peerconnection.cc`) must call
`parameters->set_encodings(params)` after mutating encodings — the wrapper's
`encodings()` getter returns copies, and without the write-back every
per-encoding field (`maxBitrate`, `minBitrate`, `scaleResolutionDownBy`, …) is
a silent no-op. That fix lives in the plugin source (in git), not here.

## Source pins (reproducibility)

| Component | Repo | Revision |
|---|---|---|
| WebRTC core | `https://github.com/webrtc-sdk/webrtc.git` | `aaeeee8077eb0a4cad1c9494e9c6433c751ef663` (branch `m144_release`) |
| C++ wrapper | `https://github.com/webrtc-sdk/libwebrtc.git` | `be9743f` + `hollow-screencast.patch` |

**Binaries and headers must always move together** — `SetContentHint` is a
vtable slot; a stock binary paired with patched headers (or vice versa) is
undefined behavior at runtime or a compile error. When extending the wrapper
API, append new virtuals at the **end** of the class so existing slot indices
stay valid.

**Never push Hollow patches to the upstream webrtc-sdk repos.** Keep local
wrapper clones without a configured remote (or with pushes disabled) so an
accidental `git push`/PR cannot leak the patch upstream.

## Build steps (Windows and Linux)

Requires ~30 GB disk, Python 3, git, curl. On Windows additionally Visual
Studio 2022 with the C++ workload and Windows SDK.

### 1. depot_tools + source checkout

```bash
mkdir libwebrtc-build && cd libwebrtc-build
git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"        # Windows: $env:PATH = "$PWD\depot_tools;$env:PATH"

cat > .gclient <<'EOF'
solutions = [
  {
    "name"        : 'src',
    "url"         : 'https://github.com/webrtc-sdk/webrtc.git@aaeeee8077eb0a4cad1c9494e9c6433c751ef663',
    "deps_file"   : 'DEPS',
    "managed"     : False,
    "custom_deps" : {},
    "custom_vars": {},
  },
]
target_os  = ['linux']    # or ['win']
EOF

gclient sync --no-history
```

Windows only, before any gn/ninja step:
`set DEPOT_TOOLS_WIN_TOOLCHAIN=0` and `set GYP_MSVS_VERSION=2022`.

Gotchas learned the hard way (2026-07-19 Linux bring-up):

- gclient cannot shallow-fetch a bare commit SHA from GitHub — clone the
  branch shallow, `git fetch --deepen=300` until the pinned commit exists,
  then check it out (and drop the `@pin` from `.gclient`; `managed: False`
  means gclient won't move your checkout).
- If GitHub is slow/flaky from the build box, set
  `git config --global http.version HTTP/1.1` and retry; or transfer an
  existing checkout over the LAN — after a cross-OS transfer run
  `git reset --hard` in EVERY repo (CRLF working trees read as dirty on
  Linux and gclient refuses to sync). Never `git clean` (it would delete
  the planted toolchain below).
- The clang + sysroot hooks can be pre-seeded offline: extract the clang
  tarball to `src/third_party/llvm-build/Release+Asserts/` and write the
  package version into `cr_build_revision` there; extract the sysroot to
  `src/build/linux/debian_bullseye_amd64-sysroot/` and write the exact
  download URL into `.stamp` inside it. Both hooks then no-op.

After the sync, apply the patches and wire the wrapper target:

```bash
cd src
git apply --ignore-whitespace /path/to/hollow-core-audio.patch
# root BUILD.gn: add "libwebrtc" to the default group's deps —
#   deps = [ ":webrtc", "libwebrtc" ]
```

### 2. Patched wrapper into the tree

```bash
git clone https://github.com/webrtc-sdk/libwebrtc.git wrapper
cd wrapper && git checkout be9743f && git remote remove origin
git apply /path/to/hollow-screencast.patch
cd ..
# copy the wrapper INTO the WebRTC tree (exclude .git)
rsync -a --exclude=.git wrapper/ src/libwebrtc/      # Windows: robocopy wrapper src\libwebrtc /E /XD .git
```

### 3. Generate + build

**Do NOT use the wrapper README's Linux args** — its
`use_custom_libcxx=false use_rtti=true` combination breaks against modern
chromium's libc++-modules build machinery. The proven args are the same
minimal set the Windows build uses (chromium-default custom libc++ is fine:
the wrapper API deliberately uses its own portable string/vector types, so
the consuming plugin's stdlib never crosses the ABI):

```bash
cd src
gn gen out/Linux-x64 --args='target_os="linux" target_cpu="x64" is_debug=false is_component_build=false rtc_use_h264=true ffmpeg_branding="Chrome" rtc_include_tests=false rtc_build_examples=false'
ninja -C out/Linux-x64 libwebrtc
```

Windows:

```powershell
cd src
gn gen out/Windows-x64 --args='target_os=\"win\" target_cpu=\"x64\" is_debug=false is_component_build=false rtc_use_h264=true ffmpeg_branding=\"Chrome\" rtc_include_tests=false rtc_build_examples=false'
ninja -C out/Windows-x64 libwebrtc
```

### 4. Vendor the artifacts back into this folder

Copy into `packages/flutter_webrtc/third_party/libwebrtc/`:

- Windows: `out/Windows-x64/libwebrtc.dll` + `libwebrtc.dll.lib` → `lib/`
- Linux: `out/Linux-x64/libwebrtc.so` → `lib/`
- Any changed wrapper header (e.g. `wrapper/include/rtc_video_track.h`) → `include/`

Then delete the app's stale plugin build cache before rebuilding
(`build/windows/x64/plugins/flutter_webrtc/` on Windows), and commit the
binaries + headers together.

Note: `../CMakeLists.txt` (the third_party bootstrap) detects the vendored
build and skips its stock-zip download — do not remove that guard; the stock
extract step would *replace* this folder.
