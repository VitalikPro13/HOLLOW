import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Height of the Dart header the traffic lights centre in, in points; 0
  /// leaves them where AppKit puts them (the 32 px title bar).
  private var trafficLightHeader: CGFloat = 0
  private var systemTitlebarHeight: CGFloat?
  private var trafficLightObservers: [NSObjectProtocol] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Start hidden so the user never sees the default-sized window pop up
    // (the "small black rectangle" flash) before window_manager applies our
    // real size/position and reveals it via `windowManager.show()` in Dart.
    self.setIsVisible(false)

    // Paint the window background with the Hollow dark colour so any frame the
    // compositor does show before Flutter's first paint matches the app
    // instead of flashing white/black.
    self.backgroundColor = NSColor(
      srgbRed: 0x0D / 255.0, green: 0x0F / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
    self.isOpaque = true

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "hollow/traffic_lights",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      if call.method == "setHeaderHeight", let h = call.arguments as? Double {
        self.trafficLightHeader = CGFloat(h)
        self.layoutTrafficLights()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // AppKit puts the buttons back on these, so they are moved again after.
    let center = NotificationCenter.default
    for name in [
      NSWindow.didResizeNotification,
      NSWindow.didEndLiveResizeNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ] {
      trafficLightObservers.append(
        center.addObserver(forName: name, object: self, queue: .main) {
          [weak self] _ in self?.layoutTrafficLights()
        })
    }

    super.awakeFromNib()
  }

  /// Centres the close, minimise and zoom buttons in the Dart header by
  /// resizing their titlebar container, the way Electron's
  /// trafficLightPosition does. Fullscreen belongs to the system.
  private func layoutTrafficLights() {
    guard !styleMask.contains(.fullScreen),
      let close = standardWindowButton(.closeButton),
      let mini = standardWindowButton(.miniaturizeButton),
      let zoom = standardWindowButton(.zoomButton),
      let container = close.superview?.superview
    else { return }

    if systemTitlebarHeight == nil {
      systemTitlebarHeight = container.frame.height
    }
    let height = trafficLightHeader > 0
      ? trafficLightHeader : (systemTitlebarHeight ?? container.frame.height)

    var frame = container.frame
    frame.size.height = height
    frame.origin.y = self.frame.height - height
    container.frame = frame

    let spacing = mini.frame.minX - close.frame.minX
    let left = close.frame.minX
    for (i, button) in [close, mini, zoom].enumerated() {
      button.setFrameOrigin(
        NSPoint(
          x: left + CGFloat(i) * spacing,
          y: (height - button.frame.height) / 2))
    }
  }
}
