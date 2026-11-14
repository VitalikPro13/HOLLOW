# Pinned CocoaPods specs

`macos/Podfile` and `ios/Podfile` take `WebRTC-SDK` from this spec instead of the
CocoaPods trunk. The trunk spec downloads its prebuilt binary with no checksum.
The spec here is the trunk spec with its `source` moved to a tagged GitHub release
asset and pinned by `sha256`, which CocoaPods checks before it unpacks anything.

`mdk` (the video engine behind fvp) is no longer pinned here: since fvp 0.37 it
comes through fvp's Swift package, whose `binaryTarget` names the tagged
`mdk-sdk` release and its checksum, which Swift Package Manager verifies. A pod
pin beside it embeds the framework twice and the build fails.

To bump one: take the new trunk spec, point `source.http` at the tagged release
asset, set `source.sha256` to the asset's digest (`gh api
repos/<owner>/<repo>/releases/tags/<tag>` lists it; confirm with `shasum -a 256`
on a download), keep `version` within what the plugin's podspec requires, then
run `pod install` in both `macos/` and `ios/` and commit the two Podfile.lock files.
