import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Poster stills for a video the person picked (video_thumbnail_service.dart),
/// cut by AVFoundation: phones ship no ffmpeg and neither does the Mac build.
/// Dart sends only files outside the data root, because an attachment there is
/// ciphertext and is never copied out in plain. Dart picks the frame from the
/// sampled lumas, so the rule is the same on every platform.
///
/// Every call ends by its `deadlineMs`: loading and decoding run asynchronously
/// and are cancelled at the deadline, and each call runs on its own worker, so a
/// file that hangs the decoder never holds up the next poster.
///
/// Kept identical in ios/Runner and macos/Runner (test/video_poster_native_test.dart).
enum VideoPoster {
  static let channelName = "hollow/video_poster"

  enum Answer {
    case unknownMethod
    case value(Any?)
    /// A JPEG and the video's metadata (`durationMs`, `width`, `height`).
    case frame(Data, [String: Any])
  }

  /// `sample` answers the duration, the displayed size and one luma (0-255, or
  /// null) per time; `frame` answers a JPEG no taller than `maxHeight` with the
  /// same metadata, or null.
  static func handle(_ method: String, _ arguments: Any?, _ reply: @escaping (Answer) -> Void) {
    guard method == "sample" || method == "frame" else { return reply(.unknownMethod) }
    let args = arguments as? [String: Any] ?? [:]
    guard let path = args["path"] as? String, FileManager.default.isReadableFile(atPath: path)
    else { return reply(.value(nil)) }
    let budget = min(max((args["deadlineMs"] as? NSNumber)?.intValue ?? 4000, 100), 10000)
    let deadline = DispatchTime.now() + .milliseconds(budget)
    // A movie that names other files (a reference movie) never makes us open them.
    let asset = AVURLAsset(
      url: URL(fileURLWithPath: path),
      options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    DispatchQueue.global(qos: .userInitiated).async {
      let answer: Answer
      if method == "sample" {
        let times = (args["timesMs"] as? [NSNumber] ?? []).map { $0.int64Value }
        answer = .value(sample(asset, times, deadline))
      } else {
        let atMs = (args["atMs"] as? NSNumber)?.int64Value ?? 0
        let maxHeight = (args["maxHeight"] as? NSNumber)?.doubleValue ?? 480
        answer = frame(asset, atMs, maxHeight, deadline).map { .frame($0.0, $0.1) } ?? .value(nil)
      }
      DispatchQueue.main.async { reply(answer) }
    }
  }

  /// Waits for `group` until `deadline`; false when it timed out.
  private static func arrived(_ group: DispatchGroup, by deadline: DispatchTime) -> Bool {
    group.wait(timeout: deadline) == .success
  }

  /// Duration and displayed size; zeros for whatever did not load in time.
  private static func metadata(_ asset: AVURLAsset, _ deadline: DispatchTime) -> [String: Any] {
    var meta: [String: Any] = ["durationMs": 0, "width": 0, "height": 0]
    let loaded = DispatchGroup()
    loaded.enter()
    asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { loaded.leave() }
    guard arrived(loaded, by: deadline) else {
      asset.cancelLoading()
      return meta
    }
    var error: NSError?
    if asset.statusOfValue(forKey: "duration", error: &error) == .loaded {
      let seconds = CMTimeGetSeconds(asset.duration)
      if seconds.isFinite && seconds > 0 { meta["durationMs"] = Int(seconds * 1000) }
    }
    guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
      let track = asset.tracks(withMediaType: .video).first
    else { return meta }
    let trackLoaded = DispatchGroup()
    trackLoaded.enter()
    track.loadValuesAsynchronously(forKeys: ["naturalSize", "preferredTransform"]) {
      trackLoaded.leave()
    }
    // A track has no cancel; the asset's cancels its loads.
    guard arrived(trackLoaded, by: deadline) else {
      asset.cancelLoading()
      return meta
    }
    let shown = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    meta["width"] = Int(abs(shown.width).rounded())
    meta["height"] = Int(abs(shown.height).rounded())
    return meta
  }

  private static func generator(_ asset: AVAsset, fitting box: CGSize) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = box
    let tolerance = CMTime(value: 100, timescale: 1000)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    return generator
  }

  /// The frames at `times` (ms), nil where none came by the deadline; whatever
  /// is still decoding then is cancelled.
  private static func images(
    _ generator: AVAssetImageGenerator, _ times: [Int64], _ deadline: DispatchTime
  ) -> [CGImage?] {
    guard !times.isEmpty else { return [] }
    let lock = NSLock()
    var out = [CGImage?](repeating: nil, count: times.count)
    let requested = times.map { NSValue(time: CMTime(value: $0, timescale: 1000)) }
    let done = DispatchGroup()
    requested.forEach { _ in done.enter() }
    generator.generateCGImagesAsynchronously(forTimes: requested) { asked, image, _, result, _ in
      if result == .succeeded, let image,
        let i = requested.firstIndex(where: { CMTimeCompare($0.timeValue, asked) == 0 })
      {
        lock.lock()
        out[i] = image
        lock.unlock()
      }
      done.leave()
    }
    if !arrived(done, by: deadline) { generator.cancelAllCGImageGeneration() }
    lock.lock()
    defer { lock.unlock() }
    return out
  }

  private static func sample(_ asset: AVURLAsset, _ times: [Int64], _ deadline: DispatchTime)
    -> [String: Any]
  {
    var meta = metadata(asset, deadline)
    let durationMs = Int64(meta["durationMs"] as? Int ?? 0)
    let wanted = times.filter { !($0 > 0 && durationMs > 0 && $0 >= durationMs) }
    let frames = images(generator(asset, fitting: CGSize(width: 32, height: 32)), wanted, deadline)
    var byTime: [Int64: CGImage] = [:]
    for (ms, image) in zip(wanted, frames) { if let image { byTime[ms] = image } }
    meta["lumas"] = times.map { ms -> Any in byTime[ms].flatMap(meanLuma) ?? NSNull() }
    return meta
  }

  private static func frame(
    _ asset: AVURLAsset, _ atMs: Int64, _ maxHeight: Double, _ deadline: DispatchTime
  ) -> (Data, [String: Any])? {
    let meta = metadata(asset, deadline)
    let box = CGSize(width: maxHeight * 2, height: maxHeight)
    guard let image = images(generator(asset, fitting: box), [atMs], deadline).first ?? nil
    else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? (data as Data, meta) : nil
  }

  /// Mean grey level (0-255) of the frame drawn at 16x16.
  private static func meanLuma(_ image: CGImage) -> Double? {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return nil }
    return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
  }
}
