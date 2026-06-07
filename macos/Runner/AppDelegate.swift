import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Keep the app running when the window is closed (X button) so it can live
    // in the background like the Windows tray flow. The Dart `onWindowClose`
    // handler decides whether to hide (minimize-to-tray setting) or fully quit.
    // Returning `true` here lets macOS terminate the process immediately,
    // bypassing that handler entirely.
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    // Clicking the Dock icon while the window is hidden (closed to background)
    // re-shows and focuses it — the macOS-native "restore from Dock" flow.
    if !flag {
      for window in NSApp.windows {
        if !window.isVisible {
          window.setIsVisible(true)
        }
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
