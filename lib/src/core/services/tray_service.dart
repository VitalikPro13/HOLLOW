import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';

/// Anything unread anywhere — drives the tray icon's red-dot variant. DM
/// counts go through the notification-settings-filtered badge (muted
/// conversations must not light the tray), matching the server strip.
final _trayUnreadProvider = Provider<bool>((ref) =>
    ref.watch(dmUnreadBadgeProvider) > 0 ||
    ref.watch(unreadProvider
        .select((u) => u.channelUnreadCounts.values.any((c) => c > 0))));

/// Always-visible Windows system tray icon (issue #50).
///
/// The icon lives in the tray for the whole app lifetime — not just while
/// hidden — so users can see Hollow is running and reach quick actions from
/// the right-click menu: open, mute/deafen/leave while in a call or voice
/// channel, settings, quit. The tooltip mirrors the connection status and the
/// icon swaps to a red-dot variant while anything is unread.
///
/// Windows-only by design: macOS keeps the native Dock idiom (active dot +
/// applicationShouldHandleReopen) and Linux skips the tray entirely because
/// AppIndicator needs a shell extension most distros don't ship —
/// [restoreWindow] is still shared by all desktop platforms (deep links).
class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  late ProviderContainer _container;

  /// Quit callback from main.dart — owns WebRTC disposal, Rust shutdown,
  /// single-instance lock release, and the final window destroy.
  late Future<void> Function() _quitApp;

  bool _iconVisible = false;
  bool _unreadShown = false;
  final Map<bool, String> _iconPaths = {};

  /// Called once from main() on desktop, right after the container exists.
  /// Creates the tray icon immediately on Windows; other platforms only get
  /// [restoreWindow].
  Future<void> init(
    ProviderContainer container, {
    required Future<void> Function() quitApp,
  }) async {
    _container = container;
    _quitApp = quitApp;
    if (!Platform.isWindows) return;

    trayManager.addListener(this);
    await ensureIcon();

    // Tooltip + unread badge track app state. Attached after the first frame
    // so these provider chains initialize alongside the widget tree, not
    // before runApp.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _container.listen<OverallConnection>(
        overallConnectionProvider,
        (_, next) => _updateTooltip(next),
        fireImmediately: true,
      );
      _container.listen<bool>(
        _trayUnreadProvider,
        (_, hasUnread) => _updateIcon(hasUnread),
        fireImmediately: true,
      );
    });
  }

  /// Create (or re-assert) the tray icon. Idempotent, Windows-only.
  Future<void> ensureIcon() async {
    if (!Platform.isWindows) return;
    final iconPath = await _resolveIconPath(unread: _unreadShown);
    if (iconPath == null) return;
    await trayManager.setIcon(iconPath);
    await trayManager.setContextMenu(_buildMenu());
    _iconVisible = true;
  }

  /// Remove the tray icon — quit paths only.
  Future<void> destroyIcon() async {
    _iconVisible = false;
    await trayManager.destroy();
  }

  /// Shared desktop restore: bring the window back from tray/minimized/hidden
  /// and resume animations. Used by tray clicks and deep-link foregrounding.
  Future<void> restoreWindow() async {
    if (Platform.isLinux && await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
    _container.read(windowVisibleProvider.notifier).state = true;
    SharedTickers.instance.resume();
  }

  // ---- Tray state → icon/tooltip ----

  void _updateTooltip(OverallConnection status) {
    if (!_iconVisible) return;
    unawaited(
      trayManager
          .setToolTip('Hollow — ${status.label}')
          .catchError((_) {}),
    );
  }

  void _updateIcon(bool unread) {
    if (_unreadShown == unread) return;
    _unreadShown = unread;
    if (!_iconVisible) return;
    unawaited(() async {
      final path = await _resolveIconPath(unread: unread);
      if (path != null && _unreadShown == unread) {
        await trayManager.setIcon(path);
      }
    }()
        .catchError((_) {}));
  }

  /// Locate the .ico on disk (release layout, debug layout) or extract it
  /// from the asset bundle as a last resort. Cached per variant.
  Future<String?> _resolveIconPath({required bool unread}) async {
    final cached = _iconPaths[unread];
    if (cached != null && File(cached).existsSync()) return cached;

    final asset = unread ? 'app_icon_unread.ico' : 'app_icon.ico';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir/data/flutter_assets/assets/$asset',
      if (!unread) '$exeDir/app_icon.ico',
      if (!unread) 'windows/runner/resources/app_icon.ico',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return _iconPaths[unread] = File(candidate).absolute.path;
      }
    }

    try {
      final byteData = await rootBundle.load('assets/$asset');
      final iconFile = File('${Directory.systemTemp.path}/hollow_tray_$asset');
      await iconFile.writeAsBytes(byteData.buffer.asUint8List());
      return _iconPaths[unread] = iconFile.path;
    } catch (e) {
      debugPrint('[HOLLOW-TRAY] Failed to extract $asset: $e');
      return null;
    }
  }

  // ---- Menu ----

  Menu _buildMenu() {
    // Voice items only render while actually in a call/VC — and never before
    // login (reading the call providers pre-identity would spin up their
    // dependency chains too early).
    var inVoice = false;
    var muted = false;
    var deafened = false;
    var leaveLabel = '';
    if (_container.read(identityProvider).peerId != null) {
      final vc = _container.read(voiceChannelProvider);
      final call = _container.read(callProvider);
      if (vc.isInVoiceChannel) {
        inVoice = true;
        muted = vc.isMuted;
        deafened = vc.isDeafened;
        leaveLabel = 'Leave Voice Channel';
      } else if (call.status == CallStatus.active) {
        inVoice = true;
        muted = call.isMuted;
        deafened = call.isDeafened;
        leaveLabel = 'Hang Up Call';
      }
    }

    return Menu(items: [
      MenuItem(key: 'show', label: 'Open Hollow'),
      MenuItem.separator(),
      if (inVoice) ...[
        MenuItem.checkbox(key: 'mute', label: 'Mute Microphone', checked: muted),
        MenuItem.checkbox(key: 'deafen', label: 'Deafen', checked: deafened),
        MenuItem(key: 'leave', label: leaveLabel),
        MenuItem.separator(),
      ],
      MenuItem(key: 'settings', label: 'Settings'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Hollow'),
    ]);
  }

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    unawaited(restoreWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(() async {
      // Rebuild right before showing so checkmarks and the voice section
      // reflect the state at this instant — no listeners needed.
      await trayManager.setContextMenu(_buildMenu());
      await trayManager.popUpContextMenu();
    }()
        .catchError((Object e) {
      debugPrint('[HOLLOW-TRAY] Menu popup failed: $e');
    }));
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(restoreWindow());
      case 'mute':
        _toggleVoice((n) => n.toggleMute(), (n) => n.toggleMute());
      case 'deafen':
        _toggleVoice((n) => n.toggleDeafen(), (n) => n.toggleDeafen());
      case 'leave':
        unawaited(_leaveVoice());
      case 'settings':
        unawaited(_openSettings());
      case 'quit':
        unawaited(_quitApp());
    }
  }

  // ---- Actions ----

  /// Route to whichever call surface is live — same dispatch as the voice
  /// hotkeys (issue #38): VC wins, else an active DM call.
  void _toggleVoice(
    void Function(VoiceChannelNotifier) onVc,
    void Function(CallNotifier) onCall,
  ) {
    try {
      if (_container.read(voiceChannelProvider).isInVoiceChannel) {
        onVc(_container.read(voiceChannelProvider.notifier));
      } else if (_container.read(callProvider).status == CallStatus.active) {
        onCall(_container.read(callProvider.notifier));
      }
    } catch (e) {
      debugPrint('[HOLLOW-TRAY] Voice toggle failed: $e');
    }
  }

  Future<void> _leaveVoice() async {
    try {
      if (_container.read(voiceChannelProvider).isInVoiceChannel) {
        await _container.read(voiceChannelProvider.notifier).leaveChannel();
      } else if (_container.read(callProvider).status == CallStatus.active) {
        await _container.read(callProvider.notifier).endCall();
      }
    } catch (e) {
      debugPrint('[HOLLOW-TRAY] Leave voice failed: $e');
    }
  }

  Future<void> _openSettings() async {
    await restoreWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = hollowNavigatorKey.currentContext;
      if (context == null) return;
      // toggle: false — if settings is already open (window was hidden with
      // the dialog up), just come back to it instead of closing it.
      showUserSettingsDialog(context, toggle: false);
    });
  }
}
