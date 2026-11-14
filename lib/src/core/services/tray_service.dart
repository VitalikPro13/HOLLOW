import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/ui/shell/conference_actions.dart'
    show endOrLeaveConferenceMeetingOf;

/// Anything unread anywhere, driving the tray icon's red-dot variant. DM
/// counts go through the notification-settings-filtered badge, so a muted
/// conversation never lights the tray.
final _trayUnreadProvider = Provider<bool>((ref) =>
    ref.watch(dmUnreadBadgeProvider) > 0 ||
    ref.watch(unreadProvider
        .select((u) => u.channelUnreadCounts.values.any((c) => c > 0))));

/// One row of the tray menu: a [key] the click handler dispatches on, or a
/// separator. [checked] is null for a plain item, else the checkbox state.
@immutable
class TrayEntry {
  const TrayEntry(String this.key, this.label, {this.checked});
  const TrayEntry.separator()
      : key = null,
        label = '',
        checked = null;

  final String? key;
  final String label;
  final bool? checked;
}

/// Always-visible Windows system tray icon (issue #50).
///
/// The icon stays for the whole app lifetime, not just while hidden, so users
/// can see Hollow is running and reach the quick actions. Windows-only by
/// design: macOS keeps the native Dock idiom and Linux skips the tray, since
/// AppIndicator needs a shell extension most distros do not ship.
/// [restoreWindow] is still shared by every desktop platform.
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  late ProviderContainer _container;

  /// Quit callback from main.dart, which owns WebRTC disposal, Rust shutdown,
  /// the single-instance lock release and the final window destroy.
  late Future<void> Function() _quitApp;

  bool _iconVisible = false;
  bool _unreadShown = false;
  final Map<bool, String> _iconPaths = {};

  // Held for as long as they are shown: a collected wrapper frees its native
  // handle, and a freed tray icon disappears.
  tray.TrayIcon? _icon;
  tray.Image? _image;
  // One menu for the icon's life, items created once with one listener each:
  // nativeapi keeps every listener's trampoline forever, so the menu is
  // refreshed in place, never rebuilt per click.
  tray.Menu? _menu;
  final Map<String, tray.MenuItem> _menuItems = {};
  int _nativeListeners = 0;

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

    await ensureIcon();

    // Attached after the first frame so these provider chains initialize
    // alongside the widget tree rather than before runApp.
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
    try {
      final icon = _icon ?? _createIcon();
      if (icon == null) return;
      _setImage(icon, iconPath);
      icon.setVisible(true);
      _iconVisible = true;
    } catch (e) {
      // The window and the app work without a tray; a later hide retries.
      debugPrint('[HOLLOW-TRAY] Tray icon unavailable: $e');
    }
  }

  tray.TrayIcon? _createIcon() {
    final icon = tray.TrayIcon.create();
    if (icon == null) return null;
    // The right-click event reaches us before the native side opens the
    // menu itself, so the refresh lands first and the popup's modal loop never
    // runs inside a Dart callback.
    final menu = _createMenu();
    if (menu != null) icon.setContextMenu(menu);
    icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
    _nativeListeners++;
    icon.addListener((event) {
      switch (event) {
        case tray.TrayIconClickedEvent():
          unawaited(restoreWindow());
        case tray.TrayIconRightClickedEvent():
          _refreshMenu();
        case tray.TrayIconDoubleClickedEvent():
          break;
      }
    });
    return _icon = icon;
  }

  static const _checkboxKeys = {'mute', 'deafen'};
  static const _menuKeys = ['show', 'mute', 'deafen', 'leave', 'settings', 'quit'];

  tray.Menu? _createMenu() {
    final menu = tray.Menu.create();
    if (menu == null) return null;
    for (final key in _menuKeys) {
      final item = tray.MenuItem.createWithLabelAndType(
          key,
          _checkboxKeys.contains(key)
              ? tray.MenuItemType.checkbox
              : tray.MenuItemType.normal);
      if (item == null) continue;
      _nativeListeners++;
      item.addListener((event) {
        if (event is tray.MenuItemClickedEvent) handleMenuKey(key);
      });
      _menuItems[key] = item;
    }
    _menu = menu;
    _refreshMenu();
    return menu;
  }

  /// Lays the held items out for the state at this instant, so checkmarks and
  /// the voice section are current with no listeners on the call providers.
  void _refreshMenu() {
    final menu = _menu;
    if (menu == null) return;
    try {
      menu.clear();
      for (final entry in _buildMenu()) {
        final key = entry.key;
        final item = key == null ? null : _menuItems[key];
        if (item == null) {
          menu.addSeparator();
          continue;
        }
        item.label = entry.label;
        final checked = entry.checked;
        if (checked != null) {
          item.state = checked
              ? tray.MenuItemState.checked
              : tray.MenuItemState.unchecked;
        }
        menu.addItem(item);
      }
      // A release build's only witness that right-clicks add no listeners.
      unawaited(network_api
          .logFromDart(
              message: '[HOLLOW-TRAY] menu refreshed, '
                  '$_nativeListeners native listeners')
          .catchError((_) {}));
    } catch (e) {
      debugPrint('[HOLLOW-TRAY] Menu refresh failed: $e');
    }
  }

  void _setImage(tray.TrayIcon icon, String path) {
    final image = tray.Image.fromFile(path);
    if (image == null) throw ArgumentError.value(path, 'path', 'not an image');
    icon.icon = image;
    _image?.dispose();
    _image = image;
  }

  /// Remove the tray icon — quit paths only.
  Future<void> destroyIcon() async {
    _iconVisible = false;
    final icon = _icon;
    _icon = null;
    try {
      icon?.dispose();
      for (final item in _menuItems.values) {
        item.dispose();
      }
      _menuItems.clear();
      _menu?.dispose();
      _menu = null;
      _image?.dispose();
      _image = null;
    } catch (e) {
      debugPrint('[HOLLOW-TRAY] Tray icon teardown failed: $e');
    }
  }

  /// Shared desktop restore: bring the window back from tray, minimized or
  /// hidden and resume animations. Used by tray clicks and deep links.
  Future<void> restoreWindow() async {
    if (Platform.isLinux && await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
    _container.read(windowVisibleProvider.notifier).state = true;
    SharedTickers.instance.resume();
  }

  void _updateTooltip(OverallConnection status) {
    if (!_iconVisible) return;
    try {
      _icon?.setTooltip('Hollow: ${status.label}');
    } catch (_) {}
  }

  void _updateIcon(bool unread) {
    if (_unreadShown == unread) return;
    _unreadShown = unread;
    if (!_iconVisible) return;
    unawaited(() async {
      final path = await _resolveIconPath(unread: unread);
      final icon = _icon;
      if (path != null && icon != null && _unreadShown == unread) {
        _setImage(icon, path);
      }
    }()
        .catchError((_) {}));
  }

  /// Locates the .ico on disk (release layout, then debug) or extracts it
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

  @visibleForTesting
  List<TrayEntry> debugMenu() => _buildMenu();

  /// The UI probe's way in: it never runs main(), so it hands over its own
  /// container, and its window must not be driven by window_manager.
  @visibleForTesting
  void debugAttach(ProviderContainer container,
      {required Future<void> Function() showWindow}) {
    _container = container;
    _showWindow = showWindow;
  }

  Future<void> Function()? _showWindow;

  List<TrayEntry> _buildMenu() {
    // Voice items only render while actually in a call or VC, and never
    // before login: reading the call providers pre-identity would spin up
    // their dependency chains too early.
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
        leaveLabel = !inActiveConferenceCallOf(_container.read)
            ? 'Leave Voice Channel'
            : _container.read(conferenceProvider).isHost
                ? 'End Meeting…'
                : 'Leave Meeting';
      } else if (call.status == CallStatus.active) {
        inVoice = true;
        muted = call.isMuted;
        deafened = call.isDeafened;
        leaveLabel = 'Hang Up Call';
      }
    }

    return [
      const TrayEntry('show', 'Open Hollow'),
      const TrayEntry.separator(),
      if (inVoice) ...[
        TrayEntry('mute', 'Mute Microphone', checked: muted),
        TrayEntry('deafen', 'Deafen', checked: deafened),
        TrayEntry('leave', leaveLabel),
        const TrayEntry.separator(),
      ],
      const TrayEntry('settings', 'Settings'),
      const TrayEntry.separator(),
      const TrayEntry('quit', 'Quit Hollow'),
    ];
  }

  /// The action behind a tray menu item; the UI probe clicks through here.
  void handleMenuKey(String key) {
    switch (key) {
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

  /// Routes to whichever call surface is live, the same dispatch as the voice
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

  /// A meeting is left through the meeting: a bare voice leave strands it.
  Future<void> _leaveVoice() async {
    try {
      if (inActiveConferenceCallOf(_container.read)) {
        await endOrLeaveConferenceMeetingOf(_container.read,
            showWindow: _showWindow ?? restoreWindow);
      } else if (_container.read(voiceChannelProvider).isInVoiceChannel) {
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
    // Opens, never toggles: Settings left open behind a hidden window is
    // returned to rather than closed.
    openSettings(_container.read);
  }
}
