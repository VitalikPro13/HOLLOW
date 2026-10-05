import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum HollowToastType { success, error, info }

/// Hollow-branded toast, replacing Material's SnackBar everywhere. Only one is
/// visible at a time, and a new one replaces it.
class HollowToast {
  HollowToast._();

  static OverlayEntry? _currentEntry;

  /// Set while the desktop app lock cover is up. Toasts render in the root
  /// overlay, which paints ABOVE every route, so without this they would land
  /// on the lock screen.
  static bool lockedOut = false;

  /// Shows a toast at the bottom of the screen.
  ///
  /// [overlayState] is REQUIRED from non-widget code, where the only handle is
  /// the Navigator key: `Overlay.of(navKey.currentContext)` throws, because the
  /// Navigator's own context has no Overlay ancestor. Omitted, the Overlay
  /// resolves from [context].
  static void show(
    BuildContext context,
    String message, {
    HollowToastType type = HollowToastType.info,
    Duration duration = const Duration(seconds: 3),
    OverlayState? overlayState,
    bool allowWhileLocked = false,
  }) {
    if (lockedOut && !allowWhileLocked) return;
    _dismiss();

    final overlay = overlayState ?? Overlay.of(context);
    late final OverlayEntry entry;
    late final AnimationController controller;

    entry = OverlayEntry(
      builder: (context) => _HollowToastWidget(
        message: message,
        type: type,
        onControllerReady: (c) {
          controller = c;
          Future.delayed(duration, () {
            if (entry.mounted) {
              controller.reverse().then((_) {
                if (entry.mounted) entry.remove();
                if (_currentEntry == entry) {
                  _currentEntry = null;
                }
              });
            }
          });
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);
  }

  /// Clears whatever is showing. The app lock calls this: a toast raised the
  /// instant before the cover went up would otherwise sit on top of it.
  static void dismissCurrent() => _dismiss();

  static void _dismiss() {
    if (_currentEntry != null && _currentEntry!.mounted) {
      _currentEntry!.remove();
    }
    _currentEntry = null;
  }
}

final _keepClearBoxes = <_ToastKeepClearState>{};
_HollowToastWidgetState? _shownToast;

/// Marks [child] as something no toast covers (the call bar and its hang-up):
/// while it is on screen, a toast that would overlap it rises above it.
class ToastKeepClear extends StatefulWidget {
  final Widget child;

  const ToastKeepClear({super.key, required this.child});

  @override
  State<ToastKeepClear> createState() => _ToastKeepClearState();
}

class _ToastKeepClearState extends State<ToastKeepClear> {
  bool _onstage = true;

  @override
  void initState() {
    super.initState();
    _keepClearBoxes.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A route under an opaque one stays mounted with its tickers off: out of
    // sight, with a stale rect.
    _onstage = TickerMode.valuesOf(context).enabled;
    _shownToast?._placeLater();
  }

  @override
  void dispose() {
    _keepClearBoxes.remove(this);
    _shownToast?._placeLater();
    super.dispose();
  }

  /// This box in [target]'s coordinates, or null while out of sight.
  Rect? rectIn(RenderBox target) {
    final box = context.findRenderObject();
    if (!_onstage || box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    return MatrixUtils.transformRect(
        box.getTransformTo(target), Offset.zero & box.size);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _HollowToastWidget extends StatefulWidget {
  final String message;
  final HollowToastType type;
  final ValueChanged<AnimationController> onControllerReady;

  const _HollowToastWidget({
    required this.message,
    required this.type,
    required this.onControllerReady,
  });

  @override
  State<_HollowToastWidget> createState() => _HollowToastWidgetState();
}

class _HollowToastWidgetState extends State<_HollowToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  final _cardKey = GlobalKey();
  double _restingBottom = 0;
  double _rise = 0;
  bool _placeQueued = false;

  @override
  void initState() {
    super.initState();
    _shownToast = this;
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      reverseDuration: HollowDurations.fast,
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );

    _controller.forward();
    widget.onControllerReady(_controller);
  }

  @override
  void dispose() {
    if (identical(_shownToast, this)) _shownToast = null;
    _controller.dispose();
    super.dispose();
  }

  /// Re-places the toast once this frame is laid out, when every
  /// [ToastKeepClear] box is where it will be drawn.
  void _placeLater() {
    if (_placeQueued) return;
    _placeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placeQueued = false;
      if (mounted) _keepClear();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _keepClear() {
    final overlay = Overlay.of(context).context.findRenderObject();
    final card = _cardKey.currentContext?.findRenderObject();
    if (overlay is! RenderBox || card is! RenderBox) return;
    if (!overlay.hasSize || !card.hasSize) return;
    final area = overlay.size;
    final size = card.size;
    final zones = [
      for (final box in _keepClearBoxes)
        if (box.rectIn(overlay) case final rect?)
          rect.inflate(HollowSpacing.md),
    ]..sort((a, b) => b.bottom.compareTo(a.bottom));
    var rise = 0.0;
    for (final zone in zones) {
      final toast = Rect.fromLTWH(
        (area.width - size.width) / 2,
        area.height - _restingBottom - rise - size.height,
        size.width,
        size.height,
      );
      if (toast.overlaps(zone)) rise = area.height - _restingBottom - zone.top;
    }
    if (rise != _rise) setState(() => _rise = rise);
  }

  IconData _iconForType(HollowToastType type) {
    return switch (type) {
      HollowToastType.success => LucideIcons.checkCircle,
      HollowToastType.error => LucideIcons.alertCircle,
      HollowToastType.info => LucideIcons.info,
    };
  }

  Color _colorForType(HollowToastType type, HollowTheme hollow) {
    return switch (type) {
      HollowToastType.success => hollow.success,
      HollowToastType.error => hollow.error,
      HollowToastType.info => hollow.accent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final iconColor = _colorForType(widget.type, hollow);
    // Above the keyboard, and on phones above the bottom nav and its gesture
    // inset, so a toast never covers the nav icons.
    final media = MediaQuery.of(context);
    final isMobileLayout = media.size.width < 600;
    final navClearance =
        isMobileLayout ? 56 + media.viewPadding.bottom : 0.0;
    _restingBottom = 32 + media.viewInsets.bottom + navClearance;
    _placeLater();

    return Positioned(
      bottom: _restingBottom + _rise,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedBuilder(
          animation: _opacity,
          builder: (_, child) => Transform.translate(
            offset: Offset(0, HollowMotion.rise * (1 - _opacity.value)),
            child: child,
          ),
          child: FadeTransition(
            opacity: _opacity,
            child: Material(
              color: Colors.transparent,
              child: Container(
                key: _cardKey,
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: hollow.overlay,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconForType(widget.type),
                        size: 18, color: iconColor),
                    const SizedBox(width: HollowSpacing.sm + 2),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
