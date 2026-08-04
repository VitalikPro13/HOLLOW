import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'hotkey_backend.dart';
import 'hotkey_binding.dart';

/// System-wide hotkeys on Wayland via the XDG GlobalShortcuts portal
/// (org.freedesktop.portal.GlobalShortcuts, KDE Plasma 5.25+ / GNOME 48+).
/// The compositor delivers Activated AND Deactivated per shortcut — press
/// and release — so hold-PTT works natively, with user consent handled by
/// the portal's own dialog (same family as the screen-cast picker).
///
/// Lifecycle: the D-Bus connection comes from [detect] (which also proves
/// the portal exists); the portal session is created lazily on the first
/// start() and then KEPT for the process lifetime — BindShortcuts is
/// once-per-session by spec, and bound shortcuts persist per app across
/// sessions, so keeping the session avoids re-prompting the consent dialog
/// on every call. A changed binding set closes the session and rebinds.
///
/// Trigger hints use the freedesktop shortcuts spec ("CTRL+space",
/// "CTRL+SHIFT+m"); the compositor may honor or override them — the user
/// always has the last word in the portal dialog / system settings, which
/// is why [canHandle] accepts every binding.
class WaylandPortalBackend implements HotkeyBackend {
  WaylandPortalBackend._(this._client, this._portal);

  static const _portalName = 'org.freedesktop.portal.Desktop';
  static const _portalPath = '/org/freedesktop/portal/desktop';
  static const _iface = 'org.freedesktop.portal.GlobalShortcuts';
  static const _requestIface = 'org.freedesktop.portal.Request';
  static const _sessionIface = 'org.freedesktop.portal.Session';

  final DBusClient _client;
  final DBusRemoteObject _portal;

  String? _sessionHandle;

  /// The shortcut set the live session was bound with (id → trigger hint);
  /// null while the session exists but BindShortcuts hasn't succeeded yet.
  Map<String, String?>? _boundSet;

  Map<HotkeyAction, HotkeyBinding> _bindings = const {};
  HotkeyEdgeCallback? _onEdge;
  bool Function() _isTextEditing = () => false;
  final Map<HotkeyAction, bool> _pressed = {};
  StreamSubscription<DBusSignal>? _activatedSub;
  StreamSubscription<DBusSignal>? _deactivatedSub;
  int _tokenCounter = 0;
  int _startGeneration = 0;
  Future<void>? _sessionWork;

  /// Detects a Wayland session with a GlobalShortcuts portal. Async because
  /// availability is only knowable by asking D-Bus — the controller awaits
  /// this once at init and falls back to the in-app backend on null.
  static Future<WaylandPortalBackend?> detect() async {
    if (!Platform.isLinux) return null;
    final env = Platform.environment;
    final isWayland = env['XDG_SESSION_TYPE'] == 'wayland' ||
        env['WAYLAND_DISPLAY'] != null;
    if (!isWayland) return null;

    DBusClient? client;
    try {
      client = DBusClient.session();
      final portal = DBusRemoteObject(client,
          name: _portalName, path: DBusObjectPath(_portalPath));
      final version = await portal
          .getProperty(_iface, 'version')
          .timeout(const Duration(seconds: 3));
      debugPrint('[HOLLOW-HOTKEY] GlobalShortcuts portal v$version found');
      return WaylandPortalBackend._(client, portal);
    } catch (e) {
      debugPrint('[HOLLOW-HOTKEY] No GlobalShortcuts portal: $e');
      await client?.close();
      return null;
    }
  }

  @override
  bool get isSystemWide => true;

  @override
  bool canHandle(HotkeyBinding binding) => true;

  @override
  void start(
    Map<HotkeyAction, HotkeyBinding> bindings,
    HotkeyEdgeCallback onEdge,
    bool Function() isTextEditing,
  ) {
    stop();
    _bindings = Map.of(bindings);
    _onEdge = onEdge;
    _isTextEditing = isTextEditing;
    final gen = ++_startGeneration;
    // Serialize session work (start() can be called in bursts while the
    // controller re-registers on settings loads); errors degrade to
    // "portal hotkeys inactive", logged, never thrown out of start().
    _sessionWork = (_sessionWork ?? Future.value())
        .then((_) => _ensureSession(gen))
        .catchError((Object e) {
      debugPrint('[HOLLOW-HOTKEY] Portal session setup failed: $e');
    });
  }

  @override
  void stop() {
    // Detach edge routing but KEEP the portal session — see class doc.
    _startGeneration++;
    _onEdge = null;
    _pressed.clear();
  }

  /// Full teardown (controller dispose / app shutdown).
  Future<void> close() async {
    stop();
    await _activatedSub?.cancel();
    await _deactivatedSub?.cancel();
    _activatedSub = null;
    _deactivatedSub = null;
    await _closeSession();
    await _client.close();
  }

  Future<void> _closeSession() async {
    final session = _sessionHandle;
    _sessionHandle = null;
    _boundSet = null;
    if (session == null) return;
    try {
      final obj = DBusRemoteObject(_client,
          name: _portalName, path: DBusObjectPath(session));
      await obj.callMethod(_sessionIface, 'Close', [],
          replySignature: DBusSignature(''));
    } catch (_) {
      // A dead session is already what we wanted.
    }
  }

  Map<String, String?> _wantedSet() => {
        for (final e in _bindings.entries)
          e.key.name: WaylandPortalBackend._xdgTrigger(e.value),
      };

  Future<void> _ensureSession(int gen) async {
    if (gen != _startGeneration) return; // superseded by a newer start/stop
    final wanted = _wantedSet();
    if (wanted.isEmpty) return;

    // A session bound with a DIFFERENT set can't be rebound (BindShortcuts
    // is once-per-session) — retire it. The consent dialog may reappear;
    // that's the portal's contract for changed shortcuts.
    if (_sessionHandle != null &&
        _boundSet != null &&
        !mapEquals(_boundSet, wanted)) {
      debugPrint('[HOLLOW-HOTKEY] Portal bindings changed — rebinding');
      await _closeSession();
    }
    if (_sessionHandle != null && _boundSet != null) return; // covered

    // --- CreateSession (skipped when an unbound session lingers) ---------
    if (_sessionHandle == null) {
      final token = 'hollow_hk_r${++_tokenCounter}';
      final created = await _request('CreateSession', token, [
        DBusDict.stringVariant({
          'handle_token': DBusString(token),
          'session_handle_token':
              DBusString('hollow_hk_s${++_tokenCounter}'),
        }),
      ]);
      // Spec says (s) but some portals answer with an object path —
      // DBusObjectPath extends DBusString, so one case covers both.
      final rawHandle = created['session_handle'];
      final session = rawHandle is DBusString ? rawHandle.value : null;
      if (session == null) {
        throw StateError('CreateSession returned no session_handle');
      }
      _sessionHandle = session;
    }

    // --- Signals (subscribe before binding: no missed edges) --------------
    _activatedSub ??= DBusSignalStream(_client,
            interface: _iface,
            name: 'Activated',
            path: DBusObjectPath(_portalPath))
        .listen((s) => _onSignal(s, pressed: true));
    _deactivatedSub ??= DBusSignalStream(_client,
            interface: _iface,
            name: 'Deactivated',
            path: DBusObjectPath(_portalPath))
        .listen((s) => _onSignal(s, pressed: false));

    // --- BindShortcuts ----------------------------------------------------
    final shortcuts = DBusArray(DBusSignature('(sa{sv})'), [
      for (final e in _bindings.entries)
        DBusStruct([
          DBusString(e.key.name),
          DBusDict.stringVariant({
            'description': DBusString(_describe(e.key)),
            if (wanted[e.key.name] != null)
              'preferred_trigger': DBusString(wanted[e.key.name]!),
          }),
        ]),
    ]);
    final bindToken = 'hollow_hk_r${++_tokenCounter}';
    await _request('BindShortcuts', bindToken, [
      DBusObjectPath(_sessionHandle!),
      shortcuts,
      const DBusString(''), // parent_window: none (no wl_surface handle)
      DBusDict.stringVariant({
        'handle_token': DBusString(bindToken),
      }),
    ]);
    _boundSet = wanted;
    debugPrint('[HOLLOW-HOTKEY] Portal shortcuts bound: '
        '${wanted.entries.map((e) => '${e.key}=${e.value ?? '?'}').join(', ')}');
  }

  void _onSignal(DBusSignal signal, {required bool pressed}) {
    // Activated/Deactivated: (o session_handle, s shortcut_id, t timestamp,
    // a{sv} options)
    if (signal.values.length < 2) return;
    final session = signal.values[0];
    if (session is! DBusObjectPath || session.value != _sessionHandle) return;
    final id = signal.values[1];
    if (id is! DBusString) return;
    HotkeyAction? action;
    for (final a in HotkeyAction.values) {
      if (a.name == id.value) action = a;
    }
    if (action == null) return;
    final binding = _bindings[action];
    if (binding == null) return;
    // Same bare-key rule as the pollers: a modifier-less binding must not
    // fire while typing in Hollow's own composer.
    if (pressed && binding.isBare && _isTextEditing()) return;

    final was = _pressed[action] ?? false;
    if (pressed != was) {
      _pressed[action] = pressed;
      _onEdge?.call(action, pressed);
    }
  }

  String _describe(HotkeyAction action) => switch (action) {
        HotkeyAction.pushToTalk => 'Push to talk (hold to transmit)',
        HotkeyAction.toggleMute => 'Toggle microphone mute',
        HotkeyAction.toggleDeafen => 'Toggle deafen',
      };

  /// Calls a portal method that answers via the Request::Response signal.
  /// [token] must be the same handle_token passed inside the options dict:
  /// the request path is derived from it + our unique name, and we subscribe
  /// BEFORE the call — the Response can otherwise beat a late subscription
  /// (the documented reason handle_token exists). Guaranteed consistent on
  /// any xdg-desktop-portal new enough to have GlobalShortcuts (1.14+).
  Future<Map<String, DBusValue>> _request(
      String method, String token, List<DBusValue> args) async {
    final sender =
        _client.uniqueName.replaceFirst(':', '').replaceAll('.', '_');
    final requestPath =
        DBusObjectPath('$_portalPath/request/$sender/$token');
    final responses = DBusSignalStream(_client,
        interface: _requestIface, name: 'Response', path: requestPath);
    final first = responses.first; // subscribe before the method call
    await _portal.callMethod(_iface, method, args,
        replySignature: DBusSignature('o'));
    // The consent dialog is the real wait — allow human time.
    final signal = await first.timeout(
      const Duration(seconds: 120),
      onTimeout: () => throw TimeoutException('$method response timeout'),
    );
    final code = signal.values.isNotEmpty ? signal.values[0] : null;
    if (code is! DBusUint32 || code.value != 0) {
      throw StateError('$method denied/cancelled (response=$code)');
    }
    final results = signal.values.length > 1 ? signal.values[1] : null;
    if (results is DBusDict) {
      return {
        for (final e in results.children.entries)
          (e.key as DBusString).value: e.value is DBusVariant
              ? (e.value as DBusVariant).value
              : e.value,
      };
    }
    return const {};
  }

  /// freedesktop shortcuts-spec trigger ("CTRL+SHIFT+m"), or null when the
  /// key has no xkb name in our table.
  static String? _xdgTrigger(HotkeyBinding b) {
    final key = b.xkbName;
    if (key == null) return null;
    return [
      if (b.ctrl) 'CTRL',
      if (b.shift) 'SHIFT',
      if (b.alt) 'ALT',
      key,
    ].join('+');
  }
}
