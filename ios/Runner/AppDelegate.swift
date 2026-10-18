import AVFoundation
import CryptoKit
import Flutter
import Security
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

/// The background task relay_triggers.dart holds while it closes the relay
/// socket after the app leaves the screen: Dart begins it, suspends the socket,
/// and ends it once the suspend has returned.
final class RelayBackgroundTask {
  private let channel: FlutterMethodChannel
  private var task: UIBackgroundTaskIdentifier = .invalid

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "begin":
        result(self?.begin())
      case "end":
        self?.end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The seconds iOS still grants, or nil when it sets no limit (the foreground
  /// reports the largest double).
  private func begin() -> Double? {
    if task == .invalid {
      task = UIApplication.shared.beginBackgroundTask(withName: "hollow.relay.suspend") {
        [weak self] in self?.expire()
      }
    }
    let remaining = UIApplication.shared.backgroundTimeRemaining
    return remaining < 3600 ? remaining : nil
  }

  /// Dart suspends at once; iOS ends an app whose task outlives this handler.
  private func expire() {
    channel.invokeMethod("expiring", arguments: nil)
    end()
  }

  private func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
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
  // App Group shared with the Notification Service Extension, which reads the
  // push-hints cache and the data root the app keeps here. It comes from the build
  // variant (HOLLOW_APP_GROUP) via Info.plist; a missing key means no group, never
  // a production id, and Dart then keeps its data in the private sandbox.
  private let appGroupId = Bundle.main.object(forInfoDictionaryKey: "HollowAppGroup") as? String ?? ""

  // Held here: the notification center and firebase_messaging keep it weakly.
  // Set before launch finishes, which is when firebase adopts it.
  private let foregroundBanners = ForegroundBannerPresenter()

  private var relayTriggers: RelayTriggers?
  private var relayBackgroundTask: RelayBackgroundTask?

  /// The hardware key registers before the storyboard starts the Flutter engine,
  /// so Dart's first unlock can never run without it.
  override init() {
    super.init()
    HollowHwKey.register()
  }

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
        } else if call.method == "removeDeliveredInThreads" {
          // The extension's banners of these conversations, before Dart posts
          // the populated one (a sealed wake has no collapse id to cancel by).
          // flutter_local_notifications' own posts are skipped: Dart replaces
          // those in place by id, and a removal racing that post would drop it.
          let threads = Set(call.arguments as? [String] ?? [])
          let center = UNUserNotificationCenter.current()
          center.getDeliveredNotifications { notes in
            let ids = notes
              .filter {
                threads.contains($0.request.content.threadIdentifier)
                  && $0.request.content.userInfo["NotificationId"] == nil
              }
              .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            DispatchQueue.main.async { result(nil) }
          }
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

      // hollow/relay_triggers -> network changes for relay_triggers.dart.
      let relayChannel = FlutterMethodChannel(
        name: "hollow/relay_triggers",
        binaryMessenger: controller.binaryMessenger)
      let triggers = RelayTriggers { event in
        relayChannel.invokeMethod(event, arguments: nil)
      }
      triggers.start()
      relayTriggers = triggers

      // hollow/relay_background -> the background task of the relay suspend.
      relayBackgroundTask = RelayBackgroundTask(
        channel: FlutterMethodChannel(
          name: "hollow/relay_background",
          binaryMessenger: controller.binaryMessenger))
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

/// The Secure Enclave key that ties the app lock's wrap to this iPhone
/// (`identity/hw_key.rs`). Rust calls these five C functions; Swift only runs the
/// enclave. The key is usable while the phone is unlocked, on this device only, and
/// asks for neither the passcode nor Face ID, so a new face or finger never strands
/// the identity. The extension registers nothing and binds nothing.
enum HollowHwKey {
  typealias AliasFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
  typealias ApplyFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?
  ) -> Int32
  typealias DeleteFn = @convention(c) (UnsafePointer<CChar>?) -> Void
  typealias ListFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int32
  typealias RegisterFn = @convention(c) (AliasFn, AliasFn, ApplyFn, DeleteFn, ListFn) -> Void

  /// No enclave, nothing registers, and the wrap stays Argon2id. (An Apple silicon
  /// simulator reports one and binds like a phone.)
  static func register() {
    guard SecureEnclave.isAvailable else { return }
    // RTLD_DEFAULT: the symbol lives in the hollow_core framework.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "hollow_hw_key_register")
    else {
      NSLog("[HOLLOW-HWKEY] register symbol missing")
      return
    }
    unsafeBitCast(sym, to: RegisterFn.self)(hwCreate, hwExists, hwApply, hwDelete, hwList)
    NSLog("[HOLLOW-HWKEY] registered")
  }

  static let tagPrefix = "hollow.applock.hw."

  static func tag(_ alias: UnsafePointer<CChar>?) -> Data? {
    guard let alias = alias else { return nil }
    return Data("\(tagPrefix)\(String(cString: alias))".utf8)
  }

  /// The alias of every app-lock key the keychain holds, nil when it failed to say.
  static func aliases() -> [String]? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnAttributes as String: true,
    ]
    var items: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &items)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let found = items as? [[String: Any]] else {
      NSLog("[HOLLOW-HWKEY] keychain did not list: %d", status)
      return nil
    }
    return found.compactMap { attributes in
      guard let tag = attributes[kSecAttrApplicationTag as String] as? Data,
        let text = String(data: tag, encoding: .utf8), text.hasPrefix(tagPrefix)
      else { return nil }
      return String(text.dropFirst(tagPrefix.count))
    }
  }

  /// The key under [tag], and the keychain's status: `errSecItemNotFound` is the only
  /// answer that means the key is gone.
  static func lookup(_ tag: Data) -> (SecKey?, OSStatus) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let found = item, CFGetTypeID(found) == SecKeyGetTypeID()
    else { return (nil, status == errSecSuccess ? errSecInternalError : status) }
    return ((found as! SecKey), status)
  }

  static func find(_ tag: Data) -> SecKey? { lookup(tag).0 }

  static func remove(_ tag: Data) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private let hwCreate: HollowHwKey.AliasFn = { alias in
  guard let tag = HollowHwKey.tag(alias) else { return 0 }
  HollowHwKey.remove(tag)
  guard
    let access = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil)
  else { return 0 }
  let attributes: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits as String: 256,
    kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
    kSecPrivateKeyAttrs as String: [
      kSecAttrIsPermanent as String: true,
      kSecAttrApplicationTag as String: tag,
      kSecAttrAccessControl as String: access,
    ] as [String: Any],
  ]
  var error: Unmanaged<CFError>?
  guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
    NSLog("[HOLLOW-HWKEY] key not made")
    return 0
  }
  NSLog("[HOLLOW-HWKEY] key made, level=secure enclave")
  return 1
}

/// 1 the key is there, 0 the keychain says it is not, -1 it failed to say (locked,
/// busy): Rust must never take that for a lost key.
private let hwExists: HollowHwKey.AliasFn = { alias in
  guard let tag = HollowHwKey.tag(alias) else { return -1 }
  let (key, status) = HollowHwKey.lookup(tag)
  if key != nil { return 1 }
  if status == errSecItemNotFound { return 0 }
  NSLog("[HOLLOW-HWKEY] keychain did not answer: %d", status)
  return -1
}

/// ECDH between the enclave key and the uncompressed P-256 point Rust hashed the
/// stretched secret onto: 32 bytes, the shared point's x coordinate.
private let hwApply: HollowHwKey.ApplyFn = { alias, input, length, out in
  guard let tag = HollowHwKey.tag(alias), let input = input, let out = out,
    let key = HollowHwKey.find(tag)
  else { return 0 }
  let point = Data(bytes: input, count: length)
  let peerAttributes: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    kSecAttrKeySizeInBits as String: 256,
  ]
  guard
    let peer = SecKeyCreateWithData(point as CFData, peerAttributes as CFDictionary, nil),
    let shared = SecKeyCopyKeyExchangeResult(
      key, .ecdhKeyExchangeStandard, peer, [:] as CFDictionary, nil) as Data?,
    shared.count == 32
  else { return 0 }
  shared.copyBytes(to: out, count: 32)
  return 1
}

private let hwDelete: HollowHwKey.DeleteFn = { alias in
  if let tag = HollowHwKey.tag(alias) { HollowHwKey.remove(tag) }
}

/// The held aliases, newline-separated and NUL-terminated, as many whole ones as fit
/// in [capacity]: the bytes written before the NUL, or -1 when the keychain failed.
private let hwList: HollowHwKey.ListFn = { out, capacity in
  guard let out = out, capacity > 0, let aliases = HollowHwKey.aliases() else { return -1 }
  var bytes = [UInt8]()
  for alias in aliases {
    let line = Array((bytes.isEmpty ? alias : "\n\(alias)").utf8)
    if bytes.count + line.count + 1 > capacity { break }
    bytes += line
  }
  bytes.withUnsafeBufferPointer { buffer in
    if let base = buffer.baseAddress {
      out.withMemoryRebound(to: UInt8.self, capacity: capacity) { $0.update(from: base, count: buffer.count) }
    }
  }
  out[bytes.count] = 0
  return Int32(bytes.count)
}
