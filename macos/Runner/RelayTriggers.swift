import Foundation
import Network

#if canImport(AppKit)
  import AppKit
#endif

/// Reports a new usable network path, and on macOS a wake from sleep, for
/// lib/src/core/services/relay_triggers.dart. The path at start is the
/// baseline, never a change. ios/Runner keeps an identical copy (guarded by
/// test/relay_triggers_native_test.dart).
final class RelayTriggers {
  private let monitor = NWPathMonitor()
  private let forward: (String) -> Void
  private var lastPath: String?
  private var wakeObserver: NSObjectProtocol?

  init(forward: @escaping (String) -> Void) {
    self.forward = forward
  }

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      let signature = RelayTriggers.signature(of: path)
      let usable = path.status == .satisfied
      DispatchQueue.main.async { self?.pathUpdated(signature, usable: usable) }
    }
    monitor.start(queue: DispatchQueue(label: "com.anonlisten.hollow.relay-triggers"))
    #if canImport(AppKit)
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        NSLog("[HOLLOW-TRIGGER] wake")
        self?.forward("wake")
      }
    #endif
  }

  func stop() {
    monitor.cancel()
    #if canImport(AppKit)
      if let observer = wakeObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
      }
    #endif
    wakeObserver = nil
  }

  func pathUpdated(_ signature: String, usable: Bool) {
    if lastPath == nil {
      NSLog("[HOLLOW-TRIGGER] network baseline")
    }
    let changed = RelayTriggers.isNewUsablePath(
      previous: lastPath, current: signature, usable: usable)
    lastPath = signature
    if changed {
      NSLog("[HOLLOW-TRIGGER] network changed")
      forward("network")
    }
  }

  static func isNewUsablePath(previous: String?, current: String, usable: Bool) -> Bool {
    return usable && previous != nil && previous != current
  }

  static func signature(of path: NWPath) -> String {
    let interfaces = path.availableInterfaces.map { "\($0.type):\($0.name)" }
    let gateways = path.gateways.map { "\($0)" }
    return "\(path.status) [\(interfaces.joined(separator: ","))]"
      + " [\(gateways.joined(separator: ","))]"
  }
}
