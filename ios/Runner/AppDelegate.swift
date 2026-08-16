import AVFoundation
import Flutter
import UIKit

/// The bundled UI sound pack (issue #55) on iOS.
///
/// WHY THIS EXISTS INSTEAD OF `audioplayers`: audioplayers_darwin sets the
/// shared `AVAudioSession` CATEGORY whenever a player's audio context is
/// applied, and calls `setActive(false)` once its last player stops. Doing
/// either to a live `playAndRecord` / VoiceProcessingIO session is how you lose
/// the mic mid-sentence, so every in-call cue used to be DROPPED on iOS
/// outright — which is why mute, screen share and VC join were silent on iPhone
/// while notifications (the one unguarded sound) rang fine.
///
/// `AVAudioPlayer` never touches the session on its own: it plays into whatever
/// session is already configured, which during a call is WebRTC's. So the rule
/// here is absolute — NEVER call `setCategory`, NEVER call `setActive(false)`.
/// The single `setActive(true)` is opt-in from Dart and only sent when no call
/// owns the session (activating an already-active session would be a no-op
/// anyway, but there is no reason to poke it).
final class HollowSfxPlayer {
  static let shared = HollowSfxPlayer()

  /// One player per asset, kept alive: an AVAudioPlayer that goes out of scope
  /// stops playing, and rebuilding one per blip would decode the file again.
  private var players: [String: AVAudioPlayer] = [:]
  /// The looping outgoing-call ringback (separate: it outlives the one-shots).
  private var loopPlayer: AVAudioPlayer?

  /// Resolve a Flutter asset key ("assets/sounds/x.wav") to a bundle URL.
  /// `lookupKeyForAsset` prefixes the flutter_assets path
  /// (`Frameworks/App.framework/flutter_assets/...` on iOS).
  private func assetURL(_ asset: String) -> URL? {
    let key = FlutterDartProject.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
      return nil
    }
    return URL(fileURLWithPath: path)
  }

  private func activateIfAsked(_ activate: Bool) {
    guard activate else { return }
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  func play(asset: String, volume: Float, activateSession: Bool) {
    guard let url = assetURL(asset) else { return }
    activateIfAsked(activateSession)
    do {
      let player: AVAudioPlayer
      if let cached = players[asset] {
        player = cached
      } else {
        player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        players[asset] = player
      }
      player.volume = volume
      // Restart from the top rather than queue behind the previous tail.
      player.currentTime = 0
      player.play()
    } catch {
      // Fire-and-forget by design: a UI blip must never break a channel join.
    }
  }

  func startLoop(asset: String, volume: Float, activateSession: Bool) {
    stopLoop()
    guard let url = assetURL(asset) else { return }
    activateIfAsked(activateSession)
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.numberOfLoops = -1
      player.volume = volume
      player.prepareToPlay()
      player.play()
      loopPlayer = player
    } catch {}
  }

  /// Stops the loop WITHOUT deactivating the session — see the class comment.
  func stopLoop() {
    loopPlayer?.stop()
    loopPlayer = nil
  }
}

// CLASSIC FlutterAppDelegate lifecycle (NOT the UIScene / FlutterImplicitEngineDelegate
// template). Plugins register against the AppDelegate via register(with: self), which is
// what firebase_messaging's APNs swizzling expects on iOS — Messaging.messaging().delegate
// binds correctly, the APNs device token reaches Firebase, getToken() works, pushes arrive.
//
// We deliberately do NOT use UIScene here: it provides no benefit for a single-window app,
// and adopting it would force firebase_core >= 4.6 / messaging >= 16.1 — a Firebase bump we
// have no reason to take, and one the classic-mode APNs swizzling above depends on NOT
// taking. (Flutter 3.47 raised the deployment target to iOS 15 on its own; that does NOT
// force UIScene or the Firebase bump, so the pins and this delegate stay as they are.)
// The Info.plist UIApplicationSceneManifest has been removed to match.
// See flutter/flutter#185048.
@main
@objc class AppDelegate: FlutterAppDelegate {
  // App Group shared with the Notification Service Extension. The extension reads
  // the push-hints cache (friend name + avatar) the main app writes here so it can
  // show rich push banners. Must match the group id in both entitlements files and
  // PushHintsCache (Dart).
  private let appGroupId = "group.com.anonlisten.hollow"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // hollow/app_group → returns the App Group container path so Dart can write
    // the push-hints cache there (getApplicationDocumentsDirectory is the PRIVATE
    // sandbox, which the extension cannot read — the App Group container can).
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "hollow/app_group",
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "containerPath" {
          let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: self?.appGroupId ?? "")
          result(url?.path)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      // hollow/sfx → the UI sound pack, played through AVAudioPlayer so the
      // shared AVAudioSession is left exactly as WebRTC configured it. See
      // HollowSfxPlayer for why audioplayers cannot be used in-call here.
      let sfx = FlutterMethodChannel(
        name: "hollow/sfx",
        binaryMessenger: controller.binaryMessenger)
      sfx.setMethodCallHandler { call, result in
        let args = call.arguments as? [String: Any] ?? [:]
        let asset = args["asset"] as? String ?? ""
        // NSNumber, not Double: the standard codec bridges a Dart `double`
        // through NSNumber, and a whole-number volume would arrive as an int.
        let volume = (args["volume"] as? NSNumber)?.floatValue ?? 1.0
        let activate = (args["activateSession"] as? NSNumber)?.boolValue ?? false
        switch call.method {
        case "play":
          HollowSfxPlayer.shared.play(
            asset: asset, volume: volume, activateSession: activate)
          result(nil)
        case "startLoop":
          HollowSfxPlayer.shared.startLoop(
            asset: asset, volume: volume, activateSession: activate)
          result(nil)
        case "stopLoop":
          HollowSfxPlayer.shared.stopLoop()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
