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

/// A background task Dart holds across work that must not be frozen half done:
/// the relay suspend after the app leaves the screen (relay_triggers.dart), and
/// a database write long enough to outlast the background grace (node start,
/// clearing messages). iOS ends an app frozen holding the shared container's
/// database lock (0xdead10cc). A counted task is held by every begin until its
/// own end, as two writes may overlap (a clear during a node start).
final class RelayBackgroundTask {
  private let channel: FlutterMethodChannel
  private let name: String
  private let counted: Bool
  private var holders = 0
  private var task: UIBackgroundTaskIdentifier = .invalid

  init(channel: FlutterMethodChannel, name: String = "hollow.relay.suspend", counted: Bool = false) {
    self.channel = channel
    self.name = name
    self.counted = counted
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "begin":
        result(self?.begin())
      case "end":
        self?.release()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The seconds iOS still grants, or nil when it sets no limit (the foreground
  /// reports the largest double).
  private func begin() -> Double? {
    holders += 1
    if task == .invalid {
      task = UIApplication.shared.beginBackgroundTask(withName: name) {
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

  private func release() {
    holders = max(holders - 1, 0)
    if !counted || holders == 0 {
      end()
    }
  }

  private func end() {
    holders = 0
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
  private var storageBackgroundTask: RelayBackgroundTask?

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

      // hollow/keychain_groups → the two groups App Lock names on every call
      // (app_lock_service.dart, HOL-SEC-187).
      let groups = FlutterMethodChannel(
        name: "hollow/keychain_groups",
        binaryMessenger: controller.binaryMessenger)
      groups.setMethodCallHandler { call, result in
        guard call.method == "groups", let keys = HollowHwKey.keysGroup,
          let appId = HollowHwKey.appIdGroup
        else { return result(nil) }
        result(["keys": keys, "appId": appId])
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
      // hollow/storage_background -> the task held across long database writes.
      storageBackgroundTask = RelayBackgroundTask(
        channel: FlutterMethodChannel(
          name: "hollow/storage_background",
          binaryMessenger: controller.binaryMessenger),
        name: "hollow.storage.write",
        counted: true)
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
/// (`identity/hw_key.rs`). Rust calls these six C functions; Swift only runs the
/// enclave. The key is usable while the phone is unlocked, on this device only, and
/// asks for neither the passcode nor Face ID, so a new face or finger never strands
/// the identity. The extension registers nothing and binds nothing.
///
/// HOL-SEC-187: every keychain call names one group. Keys are made in the keys
/// group (the app-ID group only where a build lacks it), found there first and then
/// in the app-ID group where 0.12.2 to 0.13 made them, and a delete names each
/// group in turn, so making a key never removes one in another group.
enum HollowHwKey {
  typealias AliasFn = @convention(c) (UnsafePointer<CChar>?) -> Int32
  typealias ApplyFn = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?
  ) -> Int32
  typealias DeleteFn = @convention(c) (UnsafePointer<CChar>?) -> Void
  typealias ListFn = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int32
  typealias RegisterFn = @convention(c) (AliasFn, AliasFn, ApplyFn, DeleteFn, ListFn, AliasFn) -> Void

  static let keysGroup = Bundle.main.object(forInfoDictionaryKey: "HollowKeysGroup") as? String
  static let appIdGroup = Bundle.main.object(forInfoDictionaryKey: "HollowAppIdGroup") as? String

  /// Lookup order: the keys group, then the app-ID group.
  static var groups: [String] { [keysGroup, appIdGroup].compactMap { $0 } }

  /// No enclave, nothing registers, and the wrap stays Argon2id. (An Apple silicon
  /// simulator reports one and binds like a phone.)
  static func register() {
    guard SecureEnclave.isAvailable, !groups.isEmpty else { return }
    // RTLD_DEFAULT: the symbol lives in the hollow_core framework.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "hollow_hw_key_register")
    else {
      NSLog("[HOLLOW-HWKEY] register symbol missing")
      return
    }
    unsafeBitCast(sym, to: RegisterFn.self)(hwCreate, hwExists, hwApply, hwDelete, hwList, hwRegroup)
    NSLog("[HOLLOW-HWKEY] registered")
  }

  static let tagPrefix = "hollow.applock.hw."

  static func tag(_ alias: UnsafePointer<CChar>?) -> Data? {
    guard let alias = alias else { return nil }
    return Data("\(tagPrefix)\(String(cString: alias))".utf8)
  }

  /// The alias of every app-lock key in either group, nil when one failed to say.
  static func aliases() -> [String]? {
    var all = Set<String>()
    for group in groups {
      let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrAccessGroup as String: group,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
      ]
      var items: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &items)
      if status == errSecItemNotFound || status == errSecMissingEntitlement { continue }
      guard status == errSecSuccess, let found = items as? [[String: Any]] else {
        NSLog("[HOLLOW-HWKEY] keychain did not list: %d", status)
        return nil
      }
      for attributes in found {
        guard let tag = attributes[kSecAttrApplicationTag as String] as? Data,
          let text = String(data: tag, encoding: .utf8), text.hasPrefix(tagPrefix)
        else { continue }
        all.insert(String(text.dropFirst(tagPrefix.count)))
      }
    }
    return all.sorted()
  }

  /// The key under [tag] in [group], and the keychain's status.
  static func lookup(_ tag: Data, in group: String) -> (SecKey?, OSStatus) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrAccessGroup as String: group,
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

  /// The key under [tag], keys group first. `errSecItemNotFound` only when no group
  /// has it; a group this build may not use counts as not holding it.
  static func lookup(_ tag: Data) -> (SecKey?, OSStatus) {
    var answer: OSStatus = errSecItemNotFound
    for group in groups {
      let (key, status) = lookup(tag, in: group)
      if key != nil { return (key, status) }
      if status != errSecItemNotFound && status != errSecMissingEntitlement { answer = status }
    }
    return (nil, answer)
  }

  static func find(_ tag: Data) -> SecKey? { lookup(tag).0 }

  static func remove(_ tag: Data, in group: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrAccessGroup as String: group,
    ]
    SecItemDelete(query as CFDictionary)
  }

  /// A fresh key under [tag] in [group], replacing one there only.
  static func create(_ tag: Data, in group: String) -> Bool {
    remove(tag, in: group)
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil)
    else { return false }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
      kSecAttrAccessGroup as String: group,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessControl as String: access,
        kSecAttrAccessGroup as String: group,
      ] as [String: Any],
    ]
    var error: Unmanaged<CFError>?
    return SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil
  }
}

/// A group key (`.k`, what a re-bind wraps under) is made only in the keys group:
/// one in the app-ID group would be lost at the team change it exists to survive.
private let hwCreate: HollowHwKey.AliasFn = { alias in
  guard let alias = alias, let tag = HollowHwKey.tag(alias) else { return 0 }
  let groups = String(cString: alias).hasSuffix(".k")
    ? [HollowHwKey.keysGroup].compactMap { $0 } : HollowHwKey.groups
  for group in groups where HollowHwKey.create(tag, in: group) {
    NSLog("[HOLLOW-HWKEY] key made, level=secure enclave, %@", group == HollowHwKey.keysGroup ? "keys group" : "app-ID group")
    return 1
  }
  NSLog("[HOLLOW-HWKEY] key not made")
  return 0
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

/// A wipe or a sweep: the alias goes in every group, each named in turn.
private let hwDelete: HollowHwKey.DeleteFn = { alias in
  guard let tag = HollowHwKey.tag(alias) else { return }
  for group in HollowHwKey.groups { HollowHwKey.remove(tag, in: group) }
}

/// 1 the key is in the keys group (now or already), 0 the system kept it in the
/// app-ID group, 2 no such key, -1 the keychain could not say or this build may not
/// use the keys group.
private let hwRegroup: HollowHwKey.AliasFn = { alias in
  guard let tag = HollowHwKey.tag(alias), let keys = HollowHwKey.keysGroup,
    let appId = HollowHwKey.appIdGroup
  else { return -1 }
  if HollowHwKey.lookup(tag, in: keys).0 != nil { return 1 }
  let query: [String: Any] = [
    kSecClass as String: kSecClassKey,
    kSecAttrApplicationTag as String: tag,
    kSecAttrAccessGroup as String: appId,
  ]
  let change: [String: Any] = [kSecAttrAccessGroup as String: keys]
  let status = SecItemUpdate(query as CFDictionary, change as CFDictionary)
  NSLog("[HOLLOW-HWKEY] move into the keys group: %d", status)
  switch status {
  case errSecSuccess: return HollowHwKey.lookup(tag, in: keys).0 != nil ? 1 : 0
  case errSecItemNotFound: return 2
  // A profile without the keys group (the personal-team build) says nothing about
  // what the system allows a release.
  case errSecInteractionNotAllowed, errSecMissingEntitlement: return -1
  default: return 0
  }
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
