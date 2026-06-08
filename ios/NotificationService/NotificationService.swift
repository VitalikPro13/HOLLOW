import UserNotifications

// Notification Service Extension — rewrites the generic "New message" push banner
// into a rich one showing the sender's real name + avatar.
//
// iOS invokes this for every push that sets `mutable-content: 1` (the sidecar already
// does). It runs in a SEPARATE process/sandbox from the app, so it CANNOT read the
// app's private encrypted DB. Instead it reads a tiny "push hints" cache that the main
// app writes into the shared App Group container (friend peer_id -> name + avatar path).
//
// Privacy: Apple/APNs only ever saw the generic "New message" + an opaque `sender`
// peer_id. The name/avatar are resolved here, on-device, from app-private data. The
// message TEXT is intentionally NOT shown — decrypting it would require linking the full
// crypto core into the extension (deferred). Body stays generic.
//
// Must never drop a push: any failure (no App Group, missing/corrupt cache, unknown
// sender) falls through to delivering the original content unchanged.
class NotificationService: UNNotificationServiceExtension {
  private let appGroupId = "group.com.anonlisten.hollow"

  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let content = (request.content.mutableCopy() as! UNMutableNotificationContent)
    self.bestAttempt = content

    // The sidecar puts the sender peer_id in the FCM `data` block; FCM surfaces
    // data fields at the top level of userInfo.
    guard
      let sender = request.content.userInfo["sender"] as? String, !sender.isEmpty,
      let container = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    else {
      contentHandler(content)
      return
    }

    // Must match the writer in PushHintsCache (Dart), which writes to
    // <AppGroupRoot>/push_hints/ — NOT under a "hollow/" subdir.
    let hintsURL = container
      .appendingPathComponent("push_hints/hints.json")

    guard
      let data = try? Data(contentsOf: hintsURL),
      let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let entry = map[sender] as? [String: Any]
    else {
      // No hint for this sender — keep the generic banner.
      contentHandler(content)
      return
    }

    if let name = entry["name"] as? String, !name.isEmpty {
      content.title = name
    }
    // Body stays generic — message text requires decryption (not available here).
    content.body = "Sent you a message"

    if let avatarPath = entry["avatar"] as? String,
       let attachment = makeAvatarAttachment(avatarPath, id: sender) {
      content.attachments = [attachment]
    }

    contentHandler(content)
  }

  // UNNotificationAttachment needs a file URL whose extension maps to a known UTI.
  // Copy the cached avatar into the extension's tmp dir with a .png name so iOS
  // accepts it. (Avatars are small PNG/JPEG from the DB.)
  private func makeAvatarAttachment(_ path: String, id: String) -> UNNotificationAttachment? {
    let src = URL(fileURLWithPath: path)
    guard let bytes = try? Data(contentsOf: src) else { return nil }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hollow_avatar_\(id).png")
    do {
      try? FileManager.default.removeItem(at: tmp)
      try bytes.write(to: tmp)
      return try UNNotificationAttachment(identifier: "avatar", url: tmp, options: nil)
    } catch {
      return nil
    }
  }

  // iOS gives the extension ~30s, then calls this. Deliver whatever we have so
  // far (at minimum the original content) — never let the push silently drop.
  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }
}
