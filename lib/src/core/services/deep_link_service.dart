import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/room_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';

/// Receives hollow:// deep links from the OS (browser clicks, other apps) on
/// every platform via app_links, and routes them into the same flows the
/// in-chat link cards use. Links arriving before the shell is mounted
/// (cold-start protocol launch) are buffered and flushed when HollowShell
/// calls [notifyShellReady].
///
/// Handled forms (see hollow_link_utils.dart):
///   hollow://join?server=ID          → confirm dialog → joinServer
///   hollow://join?room=CODE          → confirm dialog → roomProvider.join
///   hollow://share/...               → PasteLinkDialog (own confirm flow)
///   hollow://recovery?server=&token= → recovery pool join dialog (prefilled)
///   hollow://redeem/CODE             → keep a Hollow Shop support code
///   https://hollow.anonlisten.com/join#server=ID → same as join?server
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  /// Set from main.dart on desktop: restores/focuses the window before any
  /// dialog appears — links often arrive while Hollow sits hidden in tray.
  Future<void> Function()? bringToForeground;

  ProviderContainer? _container;
  StreamSubscription<Uri>? _sub;
  final List<Uri> _pending = [];
  bool _shellReady = false;

  /// Called once from main() right after the ProviderContainer exists.
  /// Instantiated before runApp so the cold-start initial link is captured.
  Future<void> init(ProviderContainer container) async {
    _container = container;

    // Self-heal the hollow:// registration on Windows every launch: covers
    // portable-zip users (no installer to write the keys) and moved installs.
    // HKCU only — no admin. The Inno installer writes the same keys.
    if (Platform.isWindows) {
      unawaited(_registerWindowsProtocol());
    }

    try {
      // uriLinkStream emits the initial (cold-start) link as well as links
      // delivered while running.
      _sub = AppLinks().uriLinkStream.listen(_onUri, onError: (Object e) {
        debugPrint('[HOLLOW] deep link stream error: $e');
      });
    } catch (e) {
      debugPrint('[HOLLOW] deep link init failed: $e');
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  /// HollowShell pings this post-frame from initState — from here on links
  /// are handled live; anything buffered during startup flushes now.
  void notifyShellReady() {
    _shellReady = true;
    if (_pending.isEmpty) return;
    final queued = List.of(_pending);
    _pending.clear();
    for (final uri in queued) {
      _onUri(uri);
    }
  }

  void _onUri(Uri uri) {
    if (!_shellReady || hollowNavigatorKey.currentState == null) {
      _pending.add(uri);
      return;
    }
    unawaited(_handle(uri).catchError((Object e) {
      debugPrint('[HOLLOW] deep link handling failed: $e');
    }));
  }

  Future<void> _handle(Uri uri) async {
    final link = classifyHollowLink(uri.toString());

    if (bringToForeground != null) {
      try {
        await bringToForeground!();
      } catch (_) {}
    }

    final context = hollowNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      _pending.add(uri);
      return;
    }

    if (link == null) {
      _toast('Unrecognized Hollow link', HollowToastType.error);
      return;
    }

    switch (link.type) {
      case HollowLinkType.serverInvite:
        await _confirmJoinServer(context, link);
      case HollowLinkType.roomInvite:
        await _confirmJoinRoom(context, link);
      case HollowLinkType.share:
        // PasteLinkDialog runs its own discover→confirm→download flow.
        showHollowDialog(
          context: context,
          builder: (_) => PasteLinkDialog(initialLink: link.fullUrl),
        );
      case HollowLinkType.recovery:
        showJoinRecoveryPoolDialog(context, prefillLink: link.fullUrl);
      case HollowLinkType.conference:
        await _confirmJoinConference(context, link);
      case HollowLinkType.redeem:
        // A store build has no shop surface at all (Apple 3.1.1 / Play), and
        // that includes the redeem dialog: the link reads as unrecognized.
        if (!ShopAvailability.available) {
          _toast('Unrecognized Hollow link', HollowToastType.error);
          return;
        }
        await showRedeemCodeDialog(context, link.id);
    }
  }

  Future<void> _confirmJoinServer(BuildContext context, HollowLink link) async {
    final servers = _container?.read(serverListProvider);
    if (servers != null && servers[link.id] != null) {
      _toast('Already a member of this server', HollowToastType.info);
      return;
    }

    final confirmed = await _confirmDialog(
      context,
      title: 'Join Server?',
      body: 'You opened a server invite link. Join this server?',
      detail: link.id,
      confirmLabel: 'Join',
    );
    if (confirmed != true) return;

    try {
      await crdt_api.joinServer(serverId: link.id, nsfwConfirmed: false);
      _toast('Joining server...', HollowToastType.info);
    } catch (e) {
      _toast('Failed to join server: $e', HollowToastType.error);
    }
  }

  Future<void> _confirmJoinConference(
      BuildContext context, HollowLink link) async {
    final confirmed = await _confirmDialog(
      context,
      title: 'Join Conference?',
      body: 'You opened a conference invite link. Ask to join this meeting?',
      detail: link.id,
      confirmLabel: 'Join',
    );
    if (confirmed != true) return;

    final container = _container;
    if (container == null) return;
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: the lobby lives in the Conferences screen — push it first.
      hollowNavigatorKey.currentState?.push(hollowMobileRoute(
        builder: (_) => const MobileConferencesRoute(),
      ));
    } else {
      // Desktop: show the lobby in the Conferences center tab.
      container.read(conferenceProvider.notifier).openTab();
    }
    unawaited(container
        .read(conferenceProvider.notifier)
        .requestJoin(link.id)
        .catchError((_) {}));
  }

  Future<void> _confirmJoinRoom(BuildContext context, HollowLink link) async {
    final confirmed = await _confirmDialog(
      context,
      title: 'Join Room?',
      body: 'You opened a room invite link. Join this room?',
      detail: link.id,
      confirmLabel: 'Join',
    );
    if (confirmed != true) return;
    _container?.read(roomProvider.notifier).join(link.fullUrl);
  }

  Future<bool?> _confirmDialog(
    BuildContext context, {
    required String title,
    required String body,
    required String detail,
    required String confirmLabel,
  }) {
    return showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final hollow = HollowTheme.of(dialogContext);
        return HollowDialog(
          title: title,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                body,
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary),
              ),
              const SizedBox(height: HollowSpacing.md),
              Text(
                detail,
                style: HollowTypography.mono.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            HollowButton.filled(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }

  void _toast(String message, HollowToastType type) {
    final context = hollowNavigatorKey.currentContext;
    final overlay = hollowNavigatorKey.currentState?.overlay;
    if (context == null || overlay == null) return;
    HollowToast.show(context, message, type: type, overlayState: overlay);
  }

  /// Write `HKCU\Software\Classes\hollow` → `"<exe>" "%1"` via reg.exe (always
  /// present on Windows, avoids a win32 package version pin). Idempotent,
  /// fire-and-forget, a few ms of hidden child processes at startup.
  Future<void> _registerWindowsProtocol() async {
    try {
      final exe = Platform.resolvedExecutable;
      Future<void> reg(String key, List<String> args) async {
        await Process.run('reg', ['add', key, ...args, '/f']);
      }

      const root = r'HKCU\Software\Classes\hollow';
      await reg(root, ['/ve', '/d', 'URL:Hollow Protocol']);
      await reg(root, ['/v', 'URL Protocol', '/d', '']);
      await reg('$root\\DefaultIcon', ['/ve', '/d', '"$exe",0']);
      await reg('$root\\shell\\open\\command', ['/ve', '/d', '"$exe" "%1"']);
    } catch (e) {
      debugPrint('[HOLLOW] hollow:// registry registration failed: $e');
    }
  }
}
