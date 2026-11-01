import CryptoKit
import Foundation
import MachO
import Security

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

/// HOL-SEC-187: library validation admits any Mach-O the team ever signed, so an old
/// Hollow framework swapped into this bundle would run inside the one process that
/// may read the keys group. The release sign stage seals the code-directory hash of
/// every Mach-O but the main executable into `Info.plist` (`HollowSealedImages`),
/// which the main executable's signature binds. At start the list is taken only from
/// `Info.plist` bytes that hash to the slot of the code directory the kernel holds
/// for this process, and every loaded image is checked against it. Any mismatch, or
/// a build that claims keychain entitlements without a bound list and a team, ends
/// the process before the Flutter engine exists. An image loaded later that fails
/// ends it too. Only a clean start offers Rust the keychain (`hollow_bundle_checked`).
enum BundleSeal {
  /// The exit status of a start the check refused.
  static let refusedStatus: Int32 = 78

  /// Every loaded image matched the bound list and this executable carries a team:
  /// the macOS App Lock may read its launch secret.
  private(set) static var verified = false

  private static var started = false
  private static var judged = Set<UInt>()
  private static var sealed: [String: Set<String>] = [:]
  private static var root = ""
  private static var mainHeader: UInt = 0
  private static var team: String?

  /// Runs the start check. A refusal logs why, shows [alert] when given, and ends
  /// the process at once (no exit handlers: a swapped library may have set some).
  static func enforceAtStart(alert: ((String) -> Void)? = nil) {
    guard let reason = checkAtStart() else { return }
    NSLog("[HOLLOW-SEAL] %@: stopping before the app starts", reason)
    alert?(reason)
    _exit(refusedStatus)
  }

  /// `nil` when the process may start, else why it may not.
  static func checkAtStart() -> String? {
    guard !started else { return nil }
    started = true
    let began = DispatchTime.now().uptimeNanoseconds
    defer {
      let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
      NSLog("[HOLLOW-SEAL] start check took %.1f ms", ms)
    }
    let claims = claimsKeychain()
    guard let (header, path) = mainImage(), let kernel = kernelDirectory(header) else {
      return claims ? "the kernel's signature of this executable could not be read" : nil
    }
    mainHeader = UInt(bitPattern: header)
    team = kernel.team
    let contents = (path as NSString).deletingLastPathComponent
    let bundle = ((contents as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    var list: [String]?
    if (contents as NSString).lastPathComponent == "MacOS",
      ((contents as NSString).deletingLastPathComponent as NSString).lastPathComponent == "Contents",
      let bytes = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist")
    {
      switch kernel.binds(bytes) {
      case .some(false): return "Info.plist changed after signing"
      case .some(true):
        let info = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        list = info?["HollowSealedImages"] as? [String]
      case .none: break
      }
    }
    guard let list = list else {
      if claims { return "no sealed image list bound to the signature" }
      NSLog("[HOLLOW-SEAL] no sealed image list: a development build, the keychain stays shut")
      return nil
    }
    if claims && team == nil { return "keychain entitlements without a team" }
    for entry in list {
      let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2, parts[0].count == 40 else { return "the sealed image list is malformed" }
      sealed[parts[1], default: []].insert(parts[0].lowercased())
    }
    root = bundle + "/"
    var clean = true
    for image in 0..<_dyld_image_count() {
      guard let header = _dyld_get_image_header(image), let name = _dyld_get_image_name(image) else {
        continue
      }
      judged.insert(UInt(bitPattern: header))
      if !accepts(header, path: String(cString: name)) { clean = false }
    }
    _dyld_register_func_for_add_image { header, _ in
      guard let header = header, !BundleSeal.judged.contains(UInt(bitPattern: header)) else { return }
      var info = Dl_info()
      let path = dladdr(header, &info) != 0 && info.dli_fname != nil ? String(cString: info.dli_fname) : ""
      if !BundleSeal.accepts(header, path: path) {
        NSLog("[HOLLOW-SEAL] a library loaded after start is not this release's: stopping")
        abort()
      }
    }
    guard clean else { return "a loaded library is not this release's" }
    guard team != nil else {
      NSLog("[HOLLOW-SEAL] every library is sealed, but this executable carries no team: the keychain stays shut")
      return nil
    }
    verified = true
    openKeychain()
    return nil
  }

  /// The image dyld loaded as the executable, never `Bundle.main`'s idea of it.
  private static func mainImage() -> (UnsafePointer<mach_header>, String)? {
    for image in 0..<_dyld_image_count() {
      guard let header = _dyld_get_image_header(image), header.pointee.filetype == UInt32(MH_EXECUTE),
        let name = _dyld_get_image_name(image), let path = resolved(String(cString: name))
      else { continue }
      return (header, path)
    }
    return nil
  }

  /// An image inside the bundle must be sealed under its path with this hash, and
  /// its code in memory must be the code that directory describes; one outside may
  /// be anything but code of our team (an old Hollow library dropped where a bare
  /// dlopen name finds it).
  private static func accepts(_ header: UnsafePointer<mach_header>, path: String) -> Bool {
    if UInt(bitPattern: header) == mainHeader { return true }
    // The OS's own libraries live in the shared cache, with no file on disk.
    let real = resolved(path) ?? path
    let directories = codeDirectories(header)
    guard real.hasPrefix(root) else {
      let ours = directories.contains { $0.team != nil && $0.team == team }
      if ours { NSLog("[HOLLOW-SEAL] code of this team outside the bundle: %@", real) }
      return !ours
    }
    let relative = String(real.dropFirst(root.count))
    guard let allowed = sealed[relative], let directory = directories.first(where: { allowed.contains($0.hash) })
    else {
      NSLog("[HOLLOW-SEAL] not sealed: %@", relative)
      return false
    }
    guard pagesMatch(header, directory) else {
      NSLog("[HOLLOW-SEAL] code in memory is not the sealed code: %@", relative)
      return false
    }
    return true
  }

  /// The most read-only pages one image has checked against its directory.
  static let pageSamples = 32

  /// Page 0 and a random sample of the image's other `__TEXT` pages, as mapped, hash
  /// to the directory's page slots. The directory in memory comes from a mapping
  /// the file can still change after the load (a signature written in place over
  /// an old library's), and dyld never writes `__TEXT`, so old code under a sealed
  /// directory fails here. Hashing every page would cost about 300 ms a start.
  static func pagesMatch(_ header: UnsafePointer<mach_header>, _ directory: Directory) -> Bool {
    guard header.pointee.magic == MH_MAGIC_64, let text = segment(header, named: "__TEXT") else { return false }
    let cd = directory.bytes
    func be32(_ at: Int) -> Int { cd[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    let hashOffset = be32(16), slots = be32(28), limit = be32(32)
    let size = Int(cd[36]), shift = Int(cd[39])
    guard size > 0, shift >= 12, shift <= 16, hashOffset + slots * size <= cd.count else { return false }
    let page = 1 << shift
    let base = UnsafeRawPointer(header)
    // Pages wholly inside __TEXT, by file offset; page 0 holds the load commands.
    let inText = (0..<slots).filter { i in
      let start = i * page
      return UInt64(start) >= text.fileoff && UInt64(min(start + page, limit)) <= text.fileoff + text.filesize
    }
    guard inText.first == 0 else { return false }
    var picked = [0]
    var rest = Array(inText.dropFirst())
    rest.shuffle()
    picked += rest.prefix(pageSamples - 1)
    for i in picked {
      let start = i * page
      let length = min(page, limit - start)
      let bytes = Data(bytes: base + (start - Int(text.fileoff)), count: length)
      guard let digest = digest(bytes, type: cd[37]),
        Array(digest.prefix(size)) == Array(cd[(hashOffset + i * size)..<(hashOffset + (i + 1) * size)])
      else { return false }
    }
    return true
  }

  private static func segment(_ header: UnsafePointer<mach_header>, named wanted: String) -> segment_command_64? {
    var cursor = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
    for _ in 0..<header.pointee.ncmds {
      let command = cursor.loadUnaligned(as: load_command.self)
      if command.cmd == UInt32(LC_SEGMENT_64) {
        let segment = cursor.loadUnaligned(as: segment_command_64.self)
        let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if name == wanted { return segment }
      }
      cursor += Int(command.cmdsize)
    }
    return nil
  }

  private static func resolved(_ path: String) -> String? {
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
  }

  /// Whether this executable's validated entitlements name any keychain group.
  private static func claimsKeychain() -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let appId = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
    let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
    return appId != nil || ((groups as? [String])?.isEmpty == false)
  }

  struct Directory {
    let hash: String
    let team: String?
    let bytes: Data

    /// Whether [plist] hashes to this directory's Info.plist slot; `nil` when the
    /// signature binds no Info.plist.
    func binds(_ plist: Data) -> Bool? {
      func be32(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
      guard bytes.count >= 40 else { return nil }
      let hashOffset = be32(16)
      let special = be32(24)
      let size = Int(bytes[36])
      guard special >= 1, size > 0, hashOffset >= size, hashOffset <= bytes.count else { return nil }
      let slot = bytes[(hashOffset - size)..<hashOffset]
      if slot.allSatisfy({ $0 == 0 }) { return nil }
      guard let digest = BundleSeal.digest(plist, type: bytes[37]) else { return false }
      return Array(digest.prefix(size)) == Array(slot)
    }
  }

  static func digest(_ data: Data, type: UInt8) -> [UInt8]? {
    switch type {
    case 1: return Array(Insecure.SHA1.hash(data: data))
    case 2, 3: return Array(SHA256.hash(data: data))
    case 4: return Array(SHA384.hash(data: data))
    default: return nil
    }
  }

  /// The executable's code directory in memory that hashes to the cdhash the
  /// kernel validated this process against (`CS_OPS_CDHASH`): a directory the disk
  /// changed since the exec has another hash and is never taken.
  private static func kernelDirectory(_ header: UnsafePointer<mach_header>) -> Directory? {
    var cdhash = [UInt8](repeating: 0, count: 20)
    guard csops(getpid(), 5, &cdhash, cdhash.count) == 0 else { return nil }
    let want = cdhash.map { String(format: "%02x", $0) }.joined()
    return codeDirectories(header).first { $0.hash == want }
  }

  /// Every code directory in the image's signature as mapped in memory.
  static func codeDirectories(_ header: UnsafePointer<mach_header>) -> [Directory] {
    guard header.pointee.magic == MH_MAGIC_64 else { return [] }
    let base = UnsafeRawPointer(header)
    var cursor = base + MemoryLayout<mach_header_64>.size
    var linkedit: segment_command_64?
    var signature: linkedit_data_command?
    var textAddress: UInt64?
    for _ in 0..<header.pointee.ncmds {
      let command = cursor.loadUnaligned(as: load_command.self)
      if command.cmd == UInt32(LC_SEGMENT_64) {
        let segment = cursor.loadUnaligned(as: segment_command_64.self)
        let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if name == "__LINKEDIT" { linkedit = segment }
        if name == "__TEXT" { textAddress = segment.vmaddr }
      } else if command.cmd == UInt32(LC_CODE_SIGNATURE) {
        signature = cursor.loadUnaligned(as: linkedit_data_command.self)
      }
      cursor += Int(command.cmdsize)
    }
    guard let linkedit = linkedit, let signature = signature, let text = textAddress,
      UInt64(signature.dataoff) >= linkedit.fileoff,
      UInt64(signature.dataoff) + UInt64(signature.datasize) <= linkedit.fileoff + linkedit.filesize
    else { return [] }
    // The image's own slide: where __TEXT landed against where it was linked.
    let slide = Int(bitPattern: UInt(bitPattern: base)) &- Int(text)
    let blob = UnsafeRawPointer(bitPattern: Int(linkedit.vmaddr) &+ slide &+ Int(UInt64(signature.dataoff) - linkedit.fileoff))
    guard let blob = blob else { return [] }
    return directories(in: blob, size: Int(signature.datasize))
  }

  /// The code directories of one embedded signature, each with its cdhash (its own
  /// hash type over the blob, the first 20 bytes) and team.
  static func directories(in blob: UnsafeRawPointer, size: Int) -> [Directory] {
    func be32(_ offset: Int) -> UInt32? {
      guard offset >= 0, offset + 4 <= size else { return nil }
      return UInt32(bigEndian: blob.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    guard be32(0) == 0xfade_0cc0, let count = be32(8), count < 64 else { return [] }
    var found: [Directory] = []
    for index in 0..<Int(count) {
      guard let type = be32(12 + index * 8), let offset = be32(16 + index * 8).map(Int.init) else { break }
      guard type == 0 || (0x1000..<0x1005).contains(type), be32(offset) == 0xfade_0c02,
        let length = be32(offset + 4).map(Int.init), length >= 44, offset + length <= size
      else { continue }
      let bytes = Data(bytes: blob + offset, count: length)
      guard let digest = digest(bytes, type: bytes[37]) else { continue }
      let hash = digest.prefix(20).map { String(format: "%02x", $0) }.joined()
      var team: String?
      let version = be32(offset + 8) ?? 0
      if version >= 0x20200, let teamOffset = be32(offset + 48).map(Int.init), teamOffset > 0, teamOffset < length {
        let tail = bytes[teamOffset...]
        team = String(decoding: tail.prefix { $0 != 0 }, as: UTF8.self)
      }
      found.append(Directory(hash: hash, team: team, bytes: bytes))
    }
    return found
  }

  /// Hands Rust the groups this executable's validated entitlements name.
  private static func openKeychain() {
    guard let task = SecTaskCreateFromSelf(nil),
      let appId = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
        as? String,
      let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        as? [String],
      let keys = groups.first(where: { $0.hasSuffix(".keys") })
    else {
      NSLog("[HOLLOW-SEAL] no keychain entitlements: the keychain stays shut")
      return
    }
    typealias Checked = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    // RTLD_DEFAULT: the symbol lives in the hollow_core framework.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "hollow_bundle_checked") else {
      NSLog("[HOLLOW-SEAL] the core has no keychain switch")
      return
    }
    let answer = keys.withCString { k in appId.withCString { a in unsafeBitCast(symbol, to: Checked.self)(k, a) } }
    NSLog("[HOLLOW-SEAL] every loaded library is this release's; keychain %@", answer == 1 ? "open" : "refused")
  }
}
