# Pinned CocoaPods specs

`macos/Podfile` and `ios/Podfile` take `mdk` and `WebRTC-SDK` from these specs
instead of the CocoaPods trunk. The trunk specs download their prebuilt binaries
with no checksum, and `mdk`'s points at a nightly URL whose contents change under
the same version (the 0.13.0 release shipped an `MDK 0.36.0` binary labelled
0.35.1). Each spec here is the trunk spec with its `source` moved to a tagged
GitHub release asset and pinned by `sha256`, which CocoaPods checks before it
unpacks anything.

`mdk` ships the `v0.36.0` release binary (MDK 0.36.0, git 9e52cc6; 0.13.0 had a
nightly build of 0.36.0, git 2a17e8d), but its spec says `0.35.1`: fvp 0.35's podspec requires
`mdk ~> 0.35.1`, so CocoaPods refuses any 0.36 label. The label moves to 0.36
with the fvp upgrade that asks for it; the `sha256` is what pins the binary.

To bump one: take the new trunk spec, point `source.http` at the tagged release
asset, set `source.sha256` to the asset's digest (`gh api
repos/<owner>/<repo>/releases/tags/<tag>` lists it; confirm with `shasum -a 256`
on a download), keep `version` within what the plugin's podspec requires, then
run `pod install` in both `macos/` and `ios/` and commit the two Podfile.lock files.
