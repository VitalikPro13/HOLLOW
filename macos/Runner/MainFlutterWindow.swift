import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
