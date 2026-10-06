import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers
import UserNotifications

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

/// Decides how a banner shows while Hollow is open (#96).
///
/// firebase_messaging takes the notification center at launch and hands every
/// foreground banner to the delegate it found there, after its own `onMessage`;
/// with none, it shows nothing. A push stays silent, since the in-app banner
/// owns the foreground; a banner Hollow posts itself (the settings test) shows
/// as its flags ask.
final class ForegroundBannerPresenter: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let info = notification.request.content.userInfo
    // Only flutter_local_notifications writes these keys.
    guard info["NotificationId"] != nil else {
      completionHandler([])
      return
    }
    var options: UNNotificationPresentationOptions = []
    if info["presentBanner"] as? Bool == true { options.insert(.banner) }
    if info["presentList"] as? Bool == true { options.insert(.list) }
    if info["presentSound"] as? Bool == true { options.insert(.sound) }
    if info["presentBadge"] as? Bool == true { options.insert(.badge) }
    completionHandler(options)
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

  // Held here: the notification center and firebase_messaging keep it weakly.
  // Set before launch finishes, which is when firebase adopts it.
  private let foregroundBanners = ForegroundBannerPresenter()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = foregroundBanners
    GeneratedPluginRegistrant.register(with: self)
    excludeDataFromBackup()
    observeSwitcher()

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
        } else if call.method == "unregisterForRemoteNotifications" {
          // A wipe: APNs stops delivering here at once, with no network. Firebase
          // registers again at the next launch, for whichever identity comes next.
          UIApplication.shared.unregisterForRemoteNotifications()
          result(nil)
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

      // hollow/privacy → phrase screens, App Lock and secrets on the clipboard
      // (privacy_screen.dart, secret_clipboard.dart).
      let privacy = FlutterMethodChannel(
        name: "hollow/privacy",
        binaryMessenger: controller.binaryMessenger)
      privacy.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "setSecureScreen":
          self?.secretScreenOpen = (call.arguments as? Bool) ?? false
          result(nil)
        case "setSwitcherCover":
          let on = (call.arguments as? Bool) ?? false
          UserDefaults.standard.set(on, forKey: AppDelegate.switcherCoverKey)
          result(nil)
        case "copySecret":
          let args = call.arguments as? [String: Any] ?? [:]
          let text = args["text"] as? String ?? ""
          let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 60
          // Never handed to the person's other devices, and gone by itself.
          UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
              .localOnly: true,
              .expirationDate: Date().addingTimeInterval(seconds),
            ])
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Backups

  /// Hollow's data never enters an iCloud or Finder backup (C-RP-03): the
  /// `.hollow` export is the only sanctioned copy, as on Android. iOS can drop
  /// the flag when a backup is restored or a folder moves, so it is set at every
  /// start, creating the folders first so the flag is on before anything lands.
  private func excludeDataFromBackup() {
    let fm = FileManager.default
    var dirs: [URL] = []
    if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
      for name in ["hollow_data", "push_hints", "push_diag"] {
        dirs.append(group.appendingPathComponent(name, isDirectory: true))
      }
    }
    if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
      dirs.append(docs.appendingPathComponent("hollow", isDirectory: true))
    }
    for dir in dirs {
      var url = dir
      do {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
      } catch {
        NSLog("[HOLLOW] backup exclusion failed for \(url.lastPathComponent): \(error)")
      }
    }
  }

  // MARK: - App switcher cover

  /// Set by Dart while App Lock is on; kept across launches so the cover is
  /// right before Dart has started.
  private static let switcherCoverKey = "hollow.switcherCover"

  /// A recovery phrase screen is up.
  private var secretScreenOpen = false
  private var privacyCover: UIView?

  // The switcher's picture is taken as the app resigns, before the lock (which
  // rises on return) could cover anything; `queue: nil` runs the cover there
  // and then, on the posting thread, not a turn later.
  private func observeSwitcher() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self = self else { return }
      if self.secretScreenOpen
        || UserDefaults.standard.bool(forKey: AppDelegate.switcherCoverKey) {
        self.showPrivacyCover()
      }
    }
    center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.privacyCover?.removeFromSuperview()
      self?.privacyCover = nil
    }
  }

  private func showPrivacyCover() {
    guard privacyCover == nil, let window = window else { return }
    let cover = UIStoryboard(name: "LaunchScreen", bundle: nil)
      .instantiateInitialViewController()?.view ?? UIView()
    if cover.backgroundColor == nil { cover.backgroundColor = .black }
    cover.frame = window.bounds
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(cover)
    privacyCover = cover
  }
}
