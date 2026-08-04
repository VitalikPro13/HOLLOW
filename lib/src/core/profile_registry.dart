import 'dart:convert';
import 'dart:io';

/// Profile registry — issue #47 (switch / erase identities).
///
/// A "profile" is just a data root: the default OS dir, the portable
/// `hollow_data` folder next to the exe, or any user-added folder. The registry
/// records which one is pinned as active plus the user's custom entries. It
/// lives at a FIXED anchor — `<default OS data root>/profiles.json` — so it is
/// readable at boot before the data root is resolved, and survives switching
/// (and erasing: `perform_pending_wipe` keeps it).
///
/// Precedence at boot (see `initHollowDataDir`):
///   `HOLLOW_DATA_DIR` env  >  pinned active profile  >  portable marker
///   detection  >  OS default.
/// The pin sits ABOVE portable detection on purpose: an installed copy with a
/// `hollow_data` folder next to the exe (implicit portable) must be able to
/// switch back to its AppData profile. A pure stick on a foreign machine has no
/// profiles.json, so portable detection still wins there. No registry / no
/// active pin = exactly the pre-#47 behavior.
///
/// Desktop-only: mobile data roots are sandboxed, and the iOS Notification
/// Service Extension opens ONE fixed App Group DB path — profile switching
/// there needs its own design.

/// One user-added profile entry. The Default and Portable rows are implicit
/// (derived from the environment) and never stored.
class HollowProfile {
  final String name;
  final String path;

  const HollowProfile({required this.name, required this.path});

  Map<String, dynamic> toJson() => {'name': name, 'path': path};

  static HollowProfile? fromJson(dynamic json) {
    if (json is! Map) return null;
    final name = json['name'];
    final path = json['path'];
    if (name is! String || path is! String || path.isEmpty) return null;
    return HollowProfile(name: name, path: path);
  }
}

class ProfileRegistry {
  /// Pinned active data root, or null = automatic (legacy detection order).
  final String? activePath;
  final List<HollowProfile> custom;

  const ProfileRegistry({this.activePath, this.custom = const []});

  ProfileRegistry copyWith({
    String? activePath,
    bool clearActive = false,
    List<HollowProfile>? custom,
  }) {
    return ProfileRegistry(
      activePath: clearActive ? null : (activePath ?? this.activePath),
      custom: custom ?? this.custom,
    );
  }
}

/// The default per-OS data root — mirrors Rust's `dirs::data_dir()/hollow`
/// (identity/keys.rs::data_dir) resolved through env vars. This is where a
/// non-portable, non-pinned install keeps its data, and where profiles.json
/// anchors. Desktop only.
String defaultDesktopDataRoot() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final appData = env['APPDATA'];
    return appData != null ? '$appData\\hollow' : r'%APPDATA%\hollow';
  }
  final home = env['HOME'] ?? '~';
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/hollow';
  }
  // Linux: XDG_DATA_HOME, default ~/.local/share.
  final xdg = env['XDG_DATA_HOME'];
  final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.local/share';
  return '$base/hollow';
}

String profileRegistryPath() =>
    '${defaultDesktopDataRoot()}${Platform.pathSeparator}profiles.json';

/// Normalize a path for equality checks: forward slashes, no trailing slash,
/// lowercased on Windows (case-insensitive filesystem).
String canonicalProfilePath(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return Platform.isWindows ? p.toLowerCase() : p;
}

bool sameProfilePath(String a, String b) =>
    canonicalProfilePath(a) == canonicalProfilePath(b);

/// Synchronous read for boot (`initHollowDataDir` runs before the first
/// frame). Missing or corrupt file = empty registry, never a throw.
ProfileRegistry readProfileRegistrySync() {
  try {
    final file = File(profileRegistryPath());
    if (!file.existsSync()) return const ProfileRegistry();
    final json = jsonDecode(file.readAsStringSync());
    if (json is! Map) return const ProfileRegistry();
    final active = json['active'];
    final custom = <HollowProfile>[];
    final list = json['profiles'];
    if (list is List) {
      for (final entry in list) {
        final p = HollowProfile.fromJson(entry);
        if (p != null) custom.add(p);
      }
    }
    return ProfileRegistry(
      activePath: (active is String && active.isNotEmpty) ? active : null,
      custom: custom,
    );
  } catch (_) {
    return const ProfileRegistry();
  }
}

/// Persist the registry. Creates the anchor dir if needed (a portable-only
/// user has no AppData dir until they first use the switcher).
Future<void> saveProfileRegistry(ProfileRegistry registry) async {
  final file = File(profileRegistryPath());
  await file.parent.create(recursive: true);
  final json = <String, dynamic>{
    'version': 1,
    if (registry.activePath != null) 'active': registry.activePath,
    'profiles': registry.custom.map((p) => p.toJson()).toList(),
  };
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}
