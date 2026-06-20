import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Writes a tiny shared "push hints" cache into the iOS App Group container so
/// the Notification Service Extension can show a friend's real name + avatar on
/// a push banner (the extension runs in a separate sandbox and cannot read the
/// app's private encrypted DB).
///
/// The cache is `{ peerId: {name, avatar} }` in `push_hints/hints.json` plus one
/// `push_hints/<peerId>.img` per friend with an avatar. Plaintext names/avatars
/// the user already displays — contained to the app-private group container,
/// never iCloud-synced, never sent to Apple. iOS-only; a no-op everywhere else.
///
/// Tier B (decrypted message text/image in the banner) is deliberately NOT here.
class PushHintsCache {
  PushHintsCache._();

  static const _channel = MethodChannel('hollow/app_group');

  /// Coalesce bursts of profile/friend events into one cache write.
  static Timer? _debounce;

  /// Resolve the iOS App Group container path via the native MethodChannel.
  /// Returns null on non-iOS or if the App Group isn't configured.
  static Future<String?> _appGroupDir() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('containerPath');
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] App Group path unavailable: $e');
      return null;
    }
  }

  /// Schedule a debounced rewrite of the hints cache from the given friend ids.
  /// Safe to call frequently (profile updates, friend-list changes); the actual
  /// disk write happens at most once per ~1.5s.
  static void scheduleWrite(Iterable<String> friendPeerIds) {
    if (!Platform.isIOS) return;
    final ids = friendPeerIds.toList(growable: false);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), () {
      writeNow(ids).catchError((e) {
        debugPrint('[HOLLOW-PUSHHINTS] write failed: $e');
      });
    });
  }

  /// Rewrite the shared push-hints cache immediately. iOS-only.
  static Future<void> writeNow(List<String> friendPeerIds) async {
    final dir = await _appGroupDir();
    if (dir == null) return;

    final base = Directory('$dir/push_hints');
    if (!base.existsSync()) base.createSync(recursive: true);

    // The friend ids are MASTER ids, but a push `sender` is the relay-attested
    // DEVICE id of the sending device (a keystone-rotated / multi-device friend
    // sends from a device id ≠ its master). The NSE does a raw `map[sender]`
    // lookup (it has no resolver), so we must additionally key each friend's hint
    // under EVERY device id that resolves to that friend's master — otherwise a
    // device-id sender misses and the banner degrades to a content-free
    // "New message" with no name/avatar/fetch. Build master → all device ids.
    final aliasesFor = <String, List<String>>{};
    try {
      for (final link in await network_api.getDeviceLinks()) {
        if (link.devicePeerId == link.masterPeerId) continue; // self-map: skip
        (aliasesFor[link.masterPeerId] ??= <String>[]).add(link.devicePeerId);
      }
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] getDeviceLinks failed (master-only): $e');
    }

    final map = <String, dynamic>{};
    final keep = <String>{}; // avatar files to retain this pass

    for (final peerId in friendPeerIds) {
      try {
        final profile = await storage_api.getProfileLight(peerId: peerId);
        final name = (profile != null && profile.displayName.isNotEmpty)
            ? profile.displayName
            : null;

        String? avatarPath;
        final bytes = await storage_api.getAvatar(peerId: peerId);
        if (bytes != null && bytes.isNotEmpty) {
          // Avatar file is keyed by the MASTER id (one per person); every alias
          // entry below points at this same file.
          final f = File('${base.path}/$peerId.img');
          await f.writeAsBytes(bytes, flush: true);
          avatarPath = f.path;
          keep.add('$peerId.img');
        }

        if (name != null || avatarPath != null) {
          final entry = {
            'name': ?name,
            'avatar': ?avatarPath,
          };
          // Key under the master AND every known device id of this friend, so
          // `map[sender]` in the NSE hits regardless of which device sent it.
          map[peerId] = entry;
          for (final deviceId in aliasesFor[peerId] ?? const <String>[]) {
            map[deviceId] = entry;
          }
        }
      } catch (e) {
        debugPrint('[HOLLOW-PUSHHINTS] skip $peerId: $e');
      }
    }

    // Atomic swap so the extension never reads a half-written file.
    try {
      final tmp = File('${base.path}/hints.json.tmp');
      await tmp.writeAsString(jsonEncode(map), flush: true);
      await tmp.rename('${base.path}/hints.json');
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] hints.json write failed: $e');
    }

    // Prune avatar files for peers no longer in the list.
    try {
      for (final entity in base.listSync()) {
        if (entity is File && entity.path.endsWith('.img')) {
          final name = entity.uri.pathSegments.last;
          if (!keep.contains(name)) {
            entity.deleteSync();
          }
        }
      }
    } catch (_) {}

    debugPrint('[HOLLOW-PUSHHINTS] wrote ${map.length} hint(s)');
  }
}
