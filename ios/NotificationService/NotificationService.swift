import UserNotifications
import Foundation  // Mach task_info / task_vm_info for the footprint measurement

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

    // Channel pushes (type=channel_wake) take a separate path: server-room
    // fetch + MLS decrypt, "Server • #channel" banner.
    if (request.content.userInfo["type"] as? String) == "channel_wake" {
      handleChannelWake(request, content: content, contentHandler: contentHandler)
      return
    }

    // The sidecar puts the sender peer_id in the FCM `data` block; FCM surfaces
    // data fields at the top level of userInfo.
    let senderId = request.content.userInfo["sender"] as? String

    // Thread by sender so iOS groups per-peer natively (mirrors Android's
    // groupKey-per-peer) AND so the Dart bg handler's local notification — which
    // sets the SAME threadIdentifier (= sender) — collapses onto this banner
    // instead of stacking a second one. Set it before any early return so even
    // the generic-fallback banner threads correctly. The matching
    // apns-collapse-id (set by the sidecar) is what lets the OS replace rather
    // than add across the APNs banner / NSE rewrite / Dart content update.
    if let sender = senderId, !sender.isEmpty {
      content.threadIdentifier = sender
    }

    guard
      let sender = senderId, !sender.isEmpty,
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
    // Tier A baseline body — replaced by real text below if the fetch succeeds.
    content.body = "Sent you a message"

    if let avatarPath = entry["avatar"] as? String,
       let attachment = makeAvatarAttachment(avatarPath, id: sender) {
      content.attachments = [attachment]
    }

    // ── Tier B: fetch + decrypt the real message text on-device ──────────────
    // PRIVACY: the APNs push carried NO content. We pull the ciphertext from OUR
    // relay (E2EE, fetch-peer mode) and decrypt it here — Apple/Google never see
    // message data. This only runs when the app is NOT active: if the app is
    // alive/backgrounded its live node already receives the message, so a second
    // fetch from the NSE would be redundant and could race the canonical ratchet.
    // When the app is force-killed (the case that matters) the NSE is the SOLE
    // writer, so run_fetch's persist-to-DB is single-writer-safe.
    if appIsActive(container) {
      log(container, "app active — skip fetch, deliver Tier A")
      contentHandler(content)
      return
    }

    let dataDir = container.appendingPathComponent("hollow_data").path
    let relay = (entry["relay"] as? String) ?? "relay.anonlisten.com"
    let started = Date()
    // ~25s of the ~30s budget; leaves headroom for delivery.
    if let cstr = hollow_push_fetch_and_decrypt(dataDir, relay, sender, "", 18, "") {
      defer { hollow_push_string_free(cstr) }
      let json = String(cString: cstr)
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      let footMB = currentFootprintMB()
      // PRIVACY: never log the decrypted JSON — it contains message plaintext.
      log(container, "fetch ok in \(elapsed)ms, footprint=\(footMB)MB, jsonLen=\(json.count)")
      if let banner = bannerContent(fromJSON: json) {
        content.body = banner.body
        if let subtitle = banner.subtitle {
          content.subtitle = subtitle
        }
      }
    } else {
      let footMB = currentFootprintMB()
      log(container, "fetch returned NULL, footprint=\(footMB)MB — deliver Tier A")
    }

    contentHandler(content)
  }

  // MARK: - Channel wake (channel push)

  /// Rewrite a channel push: fetch the buffered channel ciphertext from the
  /// relay (server-room fetch mode), decrypt via MLS on-device, and render
  /// "Server • #channel" + "Name: text". Any failure falls back to a generic
  /// channel banner — never drop the push.
  private func handleChannelWake(
    _ request: UNNotificationRequest,
    content: UNMutableNotificationContent,
    contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let info = request.content.userInfo
    let server = info["server"] as? String ?? ""
    let channel = info["channel"] as? String ?? ""
    let mention = (info["mention"] as? String) == "1"
    let sender = info["sender"] as? String ?? ""

    // Thread by server so iOS groups one server's channel banners natively;
    // the apns-collapse-id (server:channel hash) makes newer pushes REPLACE
    // the per-channel banner instead of stacking.
    if !server.isEmpty {
      content.threadIdentifier = server
    }
    content.title = "Hollow"
    content.body = mention ? "You were mentioned" : "New channel messages"

    guard
      !server.isEmpty,
      let container = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    else {
      contentHandler(content)
      return
    }

    // App alive → its live node already shows in-app notifications; deliver
    // the generic banner without racing the canonical MLS state.
    if appIsActive(container) {
      log(container, "channel wake: app active — deliver generic")
      contentHandler(content)
      return
    }

    // Relay domain from the push-hints cache when the sender is a known friend;
    // default otherwise (server members usually aren't in the hints cache).
    var relay = "relay.anonlisten.com"
    let hintsURL = container.appendingPathComponent("push_hints/hints.json")
    if !sender.isEmpty,
       let data = try? Data(contentsOf: hintsURL),
       let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let entry = map[sender] as? [String: Any],
       let r = entry["relay"] as? String, !r.isEmpty {
      relay = r
    }

    let dataDir = container.appendingPathComponent("hollow_data").path
    let started = Date()
    if let cstr = hollow_push_fetch_and_decrypt(
      dataDir, relay, sender.isEmpty ? server : sender, "", 18, server) {
      defer { hollow_push_string_free(cstr) }
      let json = String(cString: cstr)
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      // PRIVACY: never log the decrypted JSON — it contains message plaintext.
      log(container, "channel fetch ok in \(elapsed)ms, footprint=\(currentFootprintMB())MB, jsonLen=\(json.count)")
      if let banner = channelBannerContent(fromJSON: json, channel: channel) {
        content.title = banner.title
        content.body = banner.body
        if let subtitle = banner.subtitle {
          content.subtitle = subtitle
        }
      }
    } else {
      log(container, "channel fetch returned NULL, footprint=\(currentFootprintMB())MB — generic banner")
    }

    contentHandler(content)
  }

  /// Render channel-wake fetch JSON. Entries carry server/channel/sender names
  /// resolved on-device by the Rust side. Prefer the channel that triggered
  /// the push; if it decrypted nothing, fall back to the most recent channel
  /// in the burst (the replay covers the whole server room).
  private func channelBannerContent(
    fromJSON json: String, channel: String
  ) -> (title: String, body: String, subtitle: String?)? {
    guard let data = json.data(using: .utf8),
          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
          !arr.isEmpty else { return nil }

    var entries = arr.filter { ($0["channel_id"] as? String) == channel }
    if entries.isEmpty, let lastCid = arr.last?["channel_id"] as? String {
      entries = arr.filter { ($0["channel_id"] as? String) == lastCid }
    }
    guard !entries.isEmpty else { return nil }

    func line(_ m: [String: Any]) -> String {
      let text = (m["text"] as? String) ?? ""
      let name = (m["sender_name"] as? String) ?? ""
      let rendered = (text.isEmpty || text.hasPrefix("[file:"))
        ? "📷 Image"
        : (text.count > 140 ? String(text.prefix(140)) + "…" : text)
      return name.isEmpty ? rendered : "\(name): \(rendered)"
    }

    let serverName = (entries.last?["server_name"] as? String) ?? ""
    let channelName = (entries.last?["channel_name"] as? String) ?? ""
    var title = serverName.isEmpty ? "Hollow" : serverName
    if !channelName.isEmpty { title += " • #\(channelName)" }

    let body = entries.suffix(3).map(line).joined(separator: "\n")
    let subtitle = entries.count > 1 ? "\(entries.count) new messages" : nil
    return (title, body, subtitle)
  }

  // MARK: - Tier B helpers

  /// True if the app reported itself active within the last ~12s (heartbeat file
  /// the app touches on resume; cleared/aged-out on pause/kill).
  private func appIsActive(_ container: URL) -> Bool {
    let url = container.appendingPathComponent("push_diag/app_active.txt")
    guard let s = try? String(contentsOf: url, encoding: .utf8),
          let ts = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return (Date().timeIntervalSince1970 - ts) < 12.0
  }

  /// Rendered banner content from the fetch JSON.
  struct BannerContent {
    let body: String       // multi-line: the last few messages
    let subtitle: String?  // "N new messages" when >1, else nil
    let count: Int         // number of messages this fetch returned
  }

  /// Render the fetch JSON into banner content. JSON is an ARRAY (the relay
  /// replays the buffered messages on join, so one push often yields several):
  /// [{"text","message_id","timestamp","has_image"}].
  ///
  /// Mirrors Android's per-peer card: show the LAST 3 messages as a multi-line
  /// body + an "N new messages" subtitle. `apns-collapse-id` (= sender hash) means
  /// the next push for this peer REPLACES this banner, so it reads as a single
  /// accumulating per-peer card. Image-only / sentinel texts render as "📷 Image".
  /// (Cross-PUSH accumulation beyond one fetch — e.g. messages from two separate
  /// wakeups — is not kept here; each fetch drains the relay buffer, so a single
  /// fetch usually already holds the whole unread burst.)
  private func bannerContent(fromJSON json: String) -> BannerContent? {
    guard let data = json.data(using: .utf8),
          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
          !arr.isEmpty else { return nil }

    func line(_ m: [String: Any]) -> String {
      let text = (m["text"] as? String) ?? ""
      let hasImage = (m["has_image"] as? Bool) ?? false
      if text.isEmpty || text.hasPrefix("[file:") { return "📷 Image" }
      let clipped = text.count > 140 ? String(text.prefix(140)) + "…" : text
      return hasImage ? "📷 \(clipped)" : clipped
    }

    let count = arr.count
    // Last up to 3, oldest-first (arr is FIFO from the fetch).
    let lastThree = arr.suffix(3).map(line)
    let body = lastThree.joined(separator: "\n")
    let subtitle = count > 1 ? "\(count) new messages" : nil
    return BannerContent(body: body, subtitle: subtitle, count: count)
  }

  /// Current process physical memory footprint in MB — the metric iOS enforces
  /// the ~24MB NSE cap against (task_vm_info.phys_footprint). Used to validate
  /// that the fetch+crypto path fits before committing to full Tier B.
  private func currentFootprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Int(info.phys_footprint / (1024 * 1024))
  }

  /// Append a diagnostic line to the App Group log the app's Security-tab export
  /// button reads. Best-effort; never throws into the push path.
  private func log(_ container: URL, _ msg: String) {
    let dir = container.appendingPathComponent("push_diag")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("nse_metrics.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) [NSE] \(msg)\n"

    // Cap the log so it can't grow unbounded across many pushes: if it exceeds
    // 64KB, keep only the last ~16KB (trim to the next newline) before appending.
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int, size > 64 * 1024 {
      if let data = try? Data(contentsOf: url) {
        let keep = 16 * 1024
        var start = data.count - keep
        if let nl = data[start...].firstIndex(of: 0x0a) { start = nl + 1 }
        try? data.subdata(in: start..<data.count).write(to: url)
      }
    }

    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(line.data(using: .utf8)!)
      try? h.close()
    } else {
      try? line.data(using: .utf8)?.write(to: url)
    }
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
    if let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
      log(container, "serviceExtensionTimeWillExpire — delivering best attempt, footprint=\(currentFootprintMB())MB")
    }
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }
}
