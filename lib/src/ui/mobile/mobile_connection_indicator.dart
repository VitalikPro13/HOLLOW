import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/connection_visual.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// How long the link must stay down, with the app on screen, before the phone
/// says so. Returning to the app usually resumes the session in under a second.
const Duration kConnectionIndicatorDelay = Duration(milliseconds: 1500);

typedef ConnectionIndicatorContent = ({String label, bool busy});

/// What the indicator says for [connection], in the user bar's words; null
/// when there is nothing to say. A node that failed to start is no connection
/// too, from where the person sits.
ConnectionIndicatorContent? connectionIndicatorContent(
        OverallConnection connection) =>
    switch (connection) {
      OverallConnection.connected => null,
      OverallConnection.connecting ||
      OverallConnection.reconnecting ||
      OverallConnection.loading =>
        (label: connection.label, busy: true),
      OverallConnection.offline || OverallConnection.error => (
          label: OverallConnection.offline.label,
          busy: false,
        ),
    };

/// Keeps [MobileConnectionIndicator] in the root overlay while the mobile
/// layout is up, so every route pushed on the phone (pages, dialogs, sheets)
/// sits under it without opting in.
///
/// The Navigator re-stacks foreign entries above each route it pushes (#76),
/// which here is the point; the app lock removes the entry through
/// [OverlayHosts] before its cover goes up, and it returns once the lock lifts.
class MobileConnectionIndicatorHost extends ConsumerStatefulWidget {
  final Duration delay;

  const MobileConnectionIndicatorHost(
      {super.key, this.delay = kConnectionIndicatorDelay});

  static OverlayEntry? _current;

  @visibleForTesting
  static OverlayEntry? get debugEntry => _current;

  @override
  ConsumerState<MobileConnectionIndicatorHost> createState() =>
      _MobileConnectionIndicatorHostState();
}

class _MobileConnectionIndicatorHostState
    extends ConsumerState<MobileConnectionIndicatorHost> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(appLockedProvider, (_, locked) {
      if (!locked) _insertAfterFrame();
    });
    _insertAfterFrame();
  }

  /// An overlay cannot take a new entry while it builds.
  void _insertAfterFrame() {
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _insert())
      ..ensureVisualUpdate();
  }

  void _insert() {
    if (!mounted || _entry != null || ref.read(appLockedProvider)) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
        builder: (_) => MobileConnectionIndicator(delay: widget.delay));
    _entry = entry;
    MobileConnectionIndicatorHost._current = entry;
    overlay.insert(entry);
    OverlayHosts.register(this, _remove);
  }

  void _remove() {
    final entry = _entry;
    _entry = null;
    OverlayHosts.unregister(this);
    if (entry == null) return;
    if (identical(MobileConnectionIndicatorHost._current, entry)) {
      MobileConnectionIndicatorHost._current = null;
    }
    entry.remove();
    entry.dispose();
  }

  @override
  void dispose() {
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The phone's one app-wide connection line: a small card under the status
/// bar, over whatever screen is open, once the relay link has been down for
/// [delay] with the app on screen. It leaves the moment the link is back.
///
/// Never takes a tap. Silent while the app lock is up, while a call rings in
/// full screen, and over a [ConnectionIndicatorCover].
class MobileConnectionIndicator extends ConsumerStatefulWidget {
  final Duration delay;

  const MobileConnectionIndicator(
      {super.key, this.delay = kConnectionIndicatorDelay});

  @override
  ConsumerState<MobileConnectionIndicator> createState() =>
      _MobileConnectionIndicatorState();
}

class _MobileConnectionIndicatorState
    extends ConsumerState<MobileConnectionIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);
  late final Animation<double> _shown = CurvedAnimation(
      parent: _motion,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit);
  late final AppLifecycleListener _lifecycle;

  Timer? _delay;

  /// The link has stayed down for the whole delay while the app was on screen.
  bool _due = false;
  bool _away = _isAway(SchedulerBinding.instance.lifecycleState);
  bool _visible = false;

  /// Kept for the exit, when the link that ended it reads connected.
  ({String label, bool busy, Color ink})? _said;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    ConnectionIndicatorCover._changes.addListener(_onCoverChange);
    // Gone, not just transparent, once the exit has played.
    _motion.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    ConnectionIndicatorCover._changes.removeListener(_onCoverChange);
    _lifecycle.dispose();
    _motion.dispose();
    super.dispose();
  }

  /// `inactive` is still on screen (a pulled-down shade, the app switcher).
  static bool _isAway(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  void _onLifecycle(AppLifecycleState state) {
    final away = _isAway(state);
    if (away == _away || !mounted) return;
    // Either way the count starts over: on return it runs from the return.
    setState(() {
      _away = away;
      _stopCounting();
    });
    // No frames are drawn while away, so an exit would play on the return.
    if (away) {
      _visible = false;
      _motion.value = 0;
    }
  }

  void _onCoverChange() {
    if (mounted) setState(() {});
  }

  void _stopCounting() {
    _delay?.cancel();
    _delay = null;
    _due = false;
  }

  /// Counts the delay while the link is down and the app on screen.
  void _track(bool down) {
    if (!down || _away) {
      _stopCounting();
      return;
    }
    if (_due || _delay != null) return;
    _delay = Timer(widget.delay, () {
      _delay = null;
      if (mounted) setState(() => _due = true);
    });
  }

  void _animate(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (visible) {
      _motion.duration = HollowDurations.normal;
      _motion.forward();
    } else {
      _motion.reverseDuration = HollowDurations.exit;
      _motion.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final connection = ref.watch(overallConnectionProvider);
    final hasIdentity =
        ref.watch(identityProvider.select((i) => i.peerId != null));
    final locked = ref.watch(appLockedProvider);
    final ringing = ref.watch(callProvider.select((c) =>
        c.status == CallStatus.ringing &&
        c.direction == CallDirection.incoming));
    final content = connectionIndicatorContent(connection);

    // Before an identity there is no relay to reach (welcome, launch prompt).
    _track(content != null && hasIdentity);
    final visible = _due &&
        content != null &&
        !locked &&
        !ringing &&
        !ConnectionIndicatorCover.active;
    if (visible) {
      _said = (
        label: content.label,
        busy: content.busy,
        ink: connectionVisual(hollow, connection).color,
      );
    }
    _animate(visible);
    final said = _said;
    if (said == null || (!visible && _motion.isDismissed)) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: MediaQuery.paddingOf(context).top + HollowSpacing.sm,
      left: HollowSpacing.lg,
      right: HollowSpacing.lg,
      child: IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: _shown,
            builder: (_, child) => Transform.translate(
              offset: Offset(0, -HollowMotion.rise * (1 - _shown.value)),
              child: child,
            ),
            child: FadeTransition(
              opacity: _shown,
              child: Semantics(
                container: true,
                liveRegion: visible,
                label: visible ? said.label : null,
                excludeSemantics: true,
                child: _Card(said: said),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final ({String label, bool busy, Color ink}) said;

  const _Card({required this.said});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hollow.overlay,
        border: Border.all(color: hollow.border),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        boxShadow: HollowShadows.float,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        // Above every route, outside any Scaffold: it brings its own text style.
        child: DefaultTextStyle(
          style: HollowTypography.label.copyWith(color: hollow.textPrimary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              said.busy
                  ? HollowSpinner(color: said.ink)
                  : Icon(LucideIcons.wifiOff, size: 14, color: said.ink),
              const SizedBox(width: HollowSpacing.xs),
              Flexible(child: Text(said.label)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps a full-screen call surface that shows its own link state (the DM call
/// screen, a share watched full screen): while it is on screen the app-wide
/// connection indicator steps aside. A call keeps flowing peer to peer through
/// a relay outage, so a "No connection" line over a working call would
/// contradict what the person hears.
class ConnectionIndicatorCover extends StatefulWidget {
  final Widget child;

  const ConnectionIndicatorCover({super.key, required this.child});

  static final Set<Object> _onScreen = {};
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  static bool get active => _onScreen.isNotEmpty;

  @override
  State<ConnectionIndicatorCover> createState() =>
      _ConnectionIndicatorCoverState();
}

class _ConnectionIndicatorCoverState extends State<ConnectionIndicatorCover> {
  bool _onScreen = false;

  @override
  Widget build(BuildContext context) {
    // A route under an opaque one keeps its state with its tickers off.
    _set(TickerMode.valuesOf(context).enabled);
    return widget.child;
  }

  @override
  void dispose() {
    _set(false);
    super.dispose();
  }

  void _set(bool onScreen) {
    if (onScreen == _onScreen) return;
    _onScreen = onScreen;
    if (onScreen) {
      ConnectionIndicatorCover._onScreen.add(this);
    } else {
      ConnectionIndicatorCover._onScreen.remove(this);
    }
    // The indicator may not rebuild while this one builds.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => ConnectionIndicatorCover._changes.value++)
      ..ensureVisualUpdate();
  }
}
