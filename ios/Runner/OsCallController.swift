import AVFoundation
import CallKit
import Flutter
import Foundation
import flutter_webrtc

/// Tells iOS that Hollow is in a call (#154, DESIGN_OS_CALLS 2): the call the
/// app already runs, reported to CallKit so the system shows it (pill, Dynamic
/// Island, lock screen), routes and prioritises its audio, and offers mute,
/// hold and hang-up. Dart decides everything (`os_call_service.dart`); this
/// only mirrors it and forwards what the person did in the system UI.
///
/// Never rings (an incoming call is reported only once accepted in the app, as
/// a started call), never in Recents, no PushKit. Audio is owned by the fork's
/// `HollowCallAudio`: CallKit activates the session; a call CallKit refuses or
/// never activates within 3 s runs on a FALLBACK the owner activates itself.
final class OsCallController: NSObject, CXProviderDelegate {
  static let channelName = "hollow/os_call"

  private enum Phase { case starting, live, fallback }

  private struct Call {
    var phase: Phase
    var muted = false
    var title = "Hollow"
    var video = false
    /// CallKit performed our start: only now does it hear reports for the call.
    var started = false
    /// Dart said `connected` before CallKit performed the start.
    var connectPending = false
  }

  private let channel: FlutterMethodChannel
  private let provider: CXProvider
  private let callController = CXCallController()
  /// Every call Dart began and has not ended, by Dart's uuid.
  private var calls: [UUID: Call] = [:]
  /// Transactions WE requested (mute, end), so the OS's callback for them is
  /// not mistaken for the person's own action and echoed back to Dart.
  private var ownActions = Set<UUID>()
  private var activationDeadlines: [UUID: DispatchWorkItem] = [:]

  /// Debug builds only: every call takes the fallback, for the device checks of
  /// that path (Dart's `--dart-define=HOLLOW_OS_CALL_FALLBACK=1`, sent with
  /// `available`, or the same variable in the scheme's environment).
  private var forceFallback: Bool = {
    #if DEBUG
      return ProcessInfo.processInfo.environment["HOLLOW_OS_CALL_FALLBACK"] == "1"
    #else
      return false
    #endif
  }()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = false
    config.ringtoneSound = nil
    if let mask = UIImage(named: "OsCallMask")?.pngData() {
      config.iconTemplateImageData = mask
    }
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      self.handle(call, result)
    }
  }

  // MARK: - Dart -> native

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let uuid = (args["uuid"] as? String).flatMap(UUID.init(uuidString:))
    switch call.method {
    case "available":
      #if DEBUG
        if args["forceFallback"] as? Bool == true { forceFallback = true }
      #endif
      result(!forceFallback)
    case "begin":
      guard let uuid else { return result(["ok": false]) }
      result(["ok": begin(uuid, args)])
    case "connected":
      if let uuid, var known = calls[uuid], known.phase != .fallback {
        if known.started {
          provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        } else {
          // CallKit ignores a report for a call it has not started yet.
          known.connectPending = true
          calls[uuid] = known
        }
      }
      result(nil)
    case "setMuted":
      if let uuid { setMuted(uuid, (args["muted"] as? Bool) ?? false) }
      result(nil)
    case "requestUnhold":
      if let uuid, let held = calls[uuid], held.phase != .fallback {
        // Not marked as ours: the OS's answer IS the resume Dart waits for.
        request(CXSetHeldCallAction(call: uuid, onHold: false), ours: false)
      }
      result(nil)
    case "update":
      if let uuid, var known = calls[uuid], known.phase != .fallback {
        // Kept, so the start reports the latest (a blanked title stays blank).
        known.title = args["title"] as? String ?? "Hollow"
        known.video = (args["video"] as? Bool) ?? false
        calls[uuid] = known
        if known.started {
          provider.reportCall(
            with: uuid, updated: callUpdate(title: known.title, video: known.video))
        }
      }
      result(nil)
    case "end":
      if let uuid { end(uuid, reason: args["reason"] as? String ?? "local") }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Returns false when the call runs on the fallback from the start.
  private func begin(_ uuid: UUID, _ args: [String: Any]) -> Bool {
    // N2: whatever Dart no longer holds (an end that never arrived) goes, so
    // the fallback count cannot stay up.
    let live = Set((args["live"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
    for stale in calls.keys where stale != uuid && !live.contains(stale) {
      end(stale, reason: "failed")
    }
    if let known = calls[uuid] { return known.phase != .fallback }

    let title = args["title"] as? String ?? "Hollow"
    let video = (args["video"] as? Bool) ?? false
    let loud = (args["loud"] as? Bool) ?? true
    if forceFallback {
      calls[uuid] = Call(phase: .starting)
      fallBack(uuid, why: "unavailable", hadCallKitCall: false)
      return false
    }

    calls[uuid] = Call(phase: .starting, title: title, video: video)
    HollowCallAudio.callKitCallBegan()
    // Configure, never activate: CallKit activates at call priority.
    AudioUtils.prepare(forCall: loud)
    let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: title))
    start.isVideo = video
    callController.request(CXTransaction(action: start)) { [weak self] error in
      guard let error else { return }
      DispatchQueue.main.async {
        self?.fallBack(uuid, why: "start refused: \(error.localizedDescription)")
      }
    }
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, self.calls[uuid]?.phase == .starting else { return }
      self.fallBack(uuid, why: "no audio activation in 3 s")
    }
    activationDeadlines[uuid] = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
    return true
  }

  private func callUpdate(title: String, video: Bool) -> CXCallUpdate {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: title)
    update.localizedCallerName = title
    update.hasVideo = video
    update.supportsHolding = true
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    return update
  }

  private func setMuted(_ uuid: UUID, _ muted: Bool) {
    guard var call = calls[uuid], call.phase != .fallback, call.muted != muted else { return }
    call.muted = muted
    calls[uuid] = call
    // Before the start is performed CallKit refuses it; the start sends it.
    guard call.started else { return }
    request(CXSetMutedCallAction(call: uuid, muted: muted), ours: true)
  }

  private func end(_ uuid: UUID, reason: String) {
    guard let call = calls[uuid] else { return }
    forget(uuid)
    guard call.phase != .fallback else { return }
    switch reason {
    case "remote":
      provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
    case "failed":
      provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
    default:
      request(CXEndCallAction(call: uuid), ours: true)
    }
  }

  /// Drops [uuid] and gives back what it held: its CallKit slot or its share of
  /// the fallback. Idempotent.
  private func forget(_ uuid: UUID) {
    guard let call = calls.removeValue(forKey: uuid) else { return }
    activationDeadlines.removeValue(forKey: uuid)?.cancel()
    if call.phase == .fallback {
      HollowCallAudio.fallbackEnded()
    } else {
      HollowCallAudio.callKitCallEnded()
    }
  }

  /// CallKit refused the call or never gave it audio: end the system call
  /// FIRST (no ghost pill, the one call slot free again), THEN run the audio
  /// ourselves, THEN tell Dart. The uuid stays until Dart ends it.
  private func fallBack(_ uuid: UUID, why: String, hadCallKitCall: Bool = true) {
    guard var call = calls[uuid], call.phase != .fallback else { return }
    activationDeadlines.removeValue(forKey: uuid)?.cancel()
    if hadCallKitCall {
      provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
      HollowCallAudio.callKitCallEnded()
    }
    call.phase = .fallback
    calls[uuid] = call
    HollowCallAudio.fallbackBegan()
    NSLog("[HOLLOW-OSCALL] fallback: %@", why)
    channel.invokeMethod("osFailed", arguments: ["uuid": uuid.uuidString.lowercased(), "why": why])
  }

  private func request(_ action: CXCallAction, ours: Bool) {
    if ours { ownActions.insert(action.uuid) }
    callController.request(CXTransaction(action: action)) { [weak self] error in
      guard let error else { return }
      DispatchQueue.main.async {
        self?.ownActions.remove(action.uuid)
        NSLog("[HOLLOW-OSCALL] %@ refused: %@", "\(type(of: action))", error.localizedDescription)
      }
    }
  }

  private func tellDart(_ method: String, _ uuid: UUID, _ extra: [String: Any] = [:]) {
    var args = extra
    args["uuid"] = uuid.uuidString.lowercased()
    channel.invokeMethod(method, arguments: args)
  }

  // MARK: - CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {
    // callservicesd restarted and dropped every system call. Forget them (the
    // app's sessions go on); Dart begins the live one again.
    for (uuid, call) in calls where call.phase != .fallback {
      calls.removeValue(forKey: uuid)
      activationDeadlines.removeValue(forKey: uuid)?.cancel()
    }
    ownActions.removeAll()
    HollowCallAudio.callKitReset()
    channel.invokeMethod("osReset", arguments: nil)
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    // Only a start we asked for: Siri, Recents or a stray start is refused.
    guard var call = calls[action.callUUID], call.phase == .starting, !call.started else {
      return action.fail()
    }
    call.started = true
    calls[action.callUUID] = call
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    // Now CallKit knows the call: its latest name and video, what it supports,
    // and a `connected` Dart sent before this.
    provider.reportCall(
      with: action.callUUID, updated: callUpdate(title: call.title, video: call.video))
    if call.connectPending {
      provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
    }
    if call.muted {
      request(CXSetMutedCallAction(call: action.callUUID, muted: true), ours: true)
    }
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    // Nothing is ever reported ringing (decision Q2).
    action.fail()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if ownActions.remove(action.uuid) == nil, calls[action.callUUID] != nil {
      // The person hung up from the lock screen, the island, a headset or a car.
      tellDart("osEnd", action.callUUID)
      forget(action.callUUID)
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if ownActions.remove(action.uuid) == nil, var call = calls[action.callUUID] {
      call.muted = action.isMuted
      calls[action.callUUID] = call
      tellDart("osMute", action.callUUID, ["muted": action.isMuted])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    guard calls[action.callUUID] != nil else { return action.fail() }
    tellDart("osHold", action.callUUID, ["held": action.isOnHold])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    action.fail()
  }

  func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
    action.fail()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    for (uuid, call) in calls where call.phase == .starting {
      calls[uuid]?.phase = .live
      activationDeadlines.removeValue(forKey: uuid)?.cancel()
    }
    HollowCallAudio.callKitDidActivate(audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    HollowCallAudio.callKitDidDeactivate(audioSession)
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    NSLog("[HOLLOW-OSCALL] timed out: %@", "\(type(of: action))")
    action.fulfill()
  }
}
