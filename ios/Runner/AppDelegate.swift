import Flutter
import UIKit

// CLASSIC FlutterAppDelegate lifecycle (NOT the UIScene / FlutterImplicitEngineDelegate
// template). Plugins register against the AppDelegate via register(with: self), which is
// what firebase_messaging's APNs swizzling expects on iOS — Messaging.messaging().delegate
// binds correctly, the APNs device token reaches Firebase, getToken() works, pushes arrive.
//
// We deliberately do NOT use UIScene here: it provides no benefit for a single-window app,
// and adopting it would force firebase_core >= 4.6 / messaging >= 16.1, which raise the iOS
// deployment target to 15 (dropping iOS 13/14 users) for no functional gain. Classic mode
// keeps the iOS 13 floor AND fixes APNs. The Info.plist UIApplicationSceneManifest has been
// removed to match. See flutter/flutter#185048.
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
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
