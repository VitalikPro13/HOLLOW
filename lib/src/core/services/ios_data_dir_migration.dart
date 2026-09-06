import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS-only: migrates the Hollow data dir from the app's PRIVATE sandbox into
/// the shared App Group container, so the Notification Service Extension can
/// open the SAME SQLCipher DB and identity to decrypt push messages on-device.
///
/// A move, not a copy: the NSE's fetch path PERSISTS the advanced Olm session
/// and inserts message rows, so writing to a copy would let the app's
/// canonical DB drift. The App Group path is also STABLE across reinstalls,
/// unlike the app sandbox UUID.
///
/// Runs at launch BEFORE Rust opens the DB, so there is no WAL race, and is
/// idempotent once the App Group target has `messages.db`.
class IosDataDirMigration {
  IosDataDirMigration._();

  static const _channel = MethodChannel('hollow/app_group');

  /// Resolves the App Group data dir, migrating the private-sandbox dir into
  /// it on first run. Returns the path the app and NSE should both use, or
  /// null off iOS or when the App Group is unavailable, where the caller falls
  /// back to the old private path.
  static Future<String?> resolveAndMigrate(String privateHollowDir) async {
    if (!Platform.isIOS) return null;

    String? container;
    try {
      container = await _channel.invokeMethod<String>('containerPath');
    } catch (e) {
      debugPrint('[HOLLOW-MIGRATE] App Group path unavailable: $e');
      return null;
    }
    if (container == null || container.isEmpty) return null;

    final target = '$container/hollow_data';
    final targetDir = Directory(target);
    final targetDb = File('$target/messages.db');

    // Already migrated (or fresh install straight into the App Group).
    if (targetDb.existsSync()) {
      _ensureExists(targetDir);
      return target;
    }

    _ensureExists(targetDir);

    // Move everything from the private dir if it has a DB to migrate.
    final src = Directory(privateHollowDir);
    final srcDb = File('$privateHollowDir/messages.db');
    if (src.existsSync() && srcDb.existsSync()) {
      try {
        _moveDirContents(src, targetDir);
        debugPrint('[HOLLOW-MIGRATE] Migrated data dir → App Group: $target');
      } catch (e) {
        // Partial migration is dangerous; if anything fails, fall back to the
        // private dir so the app still launches with its real data.
        debugPrint('[HOLLOW-MIGRATE] Migration FAILED ($e) — using private dir');
        return null;
      }
    } else {
      debugPrint('[HOLLOW-MIGRATE] No private DB to migrate — using App Group fresh');
    }

    return target;
  }

  /// Touches the app-active heartbeat the NSE checks before fetching, on app
  /// resume: the NSE skips its own fetch while this is fresh (<12s), because
  /// the live node already receives the message.
  static Future<void> touchHeartbeat(String appGroupDataParent) async {
    if (!Platform.isIOS) return;
    try {
      // The heartbeat lives beside the NSE metrics log under push_diag/,
      // matching NotificationService.swift.
      final dir = Directory('$appGroupDataParent/push_diag');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final hb = File('${dir.path}/app_active.txt');
      final secs = DateTime.now().millisecondsSinceEpoch / 1000.0;
      await hb.writeAsString(secs.toStringAsFixed(3), flush: true);
    } catch (e) {
      debugPrint('[HOLLOW-MIGRATE] heartbeat write failed: $e');
    }
  }

  /// Ages the heartbeat out on pause, so the NSE runs its own fetch while the
  /// app is gone.
  static Future<void> clearHeartbeat(String appGroupDataParent) async {
    if (!Platform.isIOS) return;
    try {
      final hb = File('$appGroupDataParent/push_diag/app_active.txt');
      if (hb.existsSync()) await hb.writeAsString('0', flush: true);
    } catch (_) {}
  }

  static void _ensureExists(Directory d) {
    if (!d.existsSync()) d.createSync(recursive: true);
  }

  /// Copies then deletes every entry from [src] into [dst], recursively,
  /// verifying each file copied before removing the original.
  static void _moveDirContents(Directory src, Directory dst) {
    for (final entity in src.listSync()) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is File) {
        final destFile = File('${dst.path}/$name');
        entity.copySync(destFile.path);
        if (destFile.existsSync() &&
            destFile.lengthSync() == entity.lengthSync()) {
          entity.deleteSync();
        } else {
          throw StateError('copy verify failed for $name');
        }
      } else if (entity is Directory) {
        final destSub = Directory('${dst.path}/$name');
        _ensureExists(destSub);
        _moveDirContents(entity, destSub);
        entity.deleteSync(recursive: true);
      }
    }
  }
}
