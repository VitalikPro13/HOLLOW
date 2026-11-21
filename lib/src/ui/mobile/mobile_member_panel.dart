import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/shell/member_list.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The panel never takes more of the width than this, so the chat it covers
/// still shows at its edge.
const double kMemberPanelWidthShare = 0.85;

/// Nor wider than this on a tablet.
const double kMemberPanelMaxWidth = 400;

/// A slow release that carried the panel this far toward open or closed
/// lands it there.
const double _kOpenShare = 1 / 3;

/// Faster than this, in panel widths per second, decides by direction.
const double _kFlingVelocity = 1;

/// The channel page's members: a panel from the end edge over a scrim, opened
/// by the header's Members button or a drag toward the start edge, closed by
/// the scrim, its close button, a drag back, or system back.
class MobileMemberSidePanel extends StatefulWidget {
  final String serverId;

  const MobileMemberSidePanel({super.key, required this.serverId});

  @override
  State<MobileMemberSidePanel> createState() => MobileMemberSidePanelState();
}

class MobileMemberSidePanelState extends State<MobileMemberSidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this)
    ..addStatusListener(_onStatus);

  bool _shown = false;
  double _pageWidth = 0;
  double _panelWidth = 1;

  bool get isOpen => _progress.value > 0;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    // A close runs backward to dismissed; any status at zero is closed.
    final shown = status.isAnimating || _progress.value > 0;
    if (shown != _shown && mounted) setState(() => _shown = shown);
  }

  void _settle(bool open) {
    // Read per run, so a Reduce motion change applies to the next one.
    final duration = open ? HollowDurations.normal : HollowDurations.fast;
    if (duration == Duration.zero) {
      _progress.value = open ? 1 : 0;
    } else if (open) {
      _progress.animateTo(1, duration: duration, curve: HollowCurves.enter);
    } else {
      _progress.animateBack(0, duration: duration, curve: HollowCurves.exit);
    }
  }

  void open() {
    if (!_shown) setState(() => _shown = true);
    _settle(true);
  }

  void close() => _settle(false);

  /// A drag from the chat toward the start edge.
  HollowSwipeDrive startDrag() {
    if (!_shown) setState(() => _shown = true);
    _beginDrag();
    return _PanelDrive(this);
  }

  /// Where the current drag began: a release must carry it a third of the
  /// way to change the panel's state.
  double _dragFrom = 0;

  void _beginDrag() {
    _progress.stop();
    _dragFrom = _progress.value;
  }

  /// Positive [pixels] move toward closed.
  void _dragBy(double pixels) {
    _progress.value =
        (_progress.value - pixels / _panelWidth).clamp(0.0, 1.0);
  }

  /// [velocity] in panel widths per second, positive toward closed.
  void _release(double velocity) {
    if (velocity.abs() >= _kFlingVelocity) {
      _settle(velocity < 0);
    } else if (_dragFrom >= 0.5) {
      _settle(_progress.value > 1 - _kOpenShare);
    } else {
      _settle(_progress.value > _kOpenShare);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // System back closes the panel first, then the page.
      canPop: !_shown,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: !_shown
          ? const SizedBox.shrink()
          : LayoutBuilder(builder: (context, constraints) {
              _pageWidth = constraints.maxWidth;
              _panelWidth = math.min(
                  constraints.maxWidth * kMemberPanelWidthShare,
                  kMemberPanelMaxWidth);
              return _buildShown(context);
            }),
    );
  }

  Widget _buildShown(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Physical pixels toward the end edge close an end-edge panel.
    double closing(double dx) => rtl ? -dx : dx;
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, panel) {
        final t = _progress.value;
        return Stack(
          children: [
            Positioned.fill(
              child: Semantics(
                label: 'Close members',
                button: true,
                onTap: close,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: close,
                  child: ColoredBox(
                    color: hollow.scrim.withValues(alpha: hollow.scrim.a * t),
                  ),
                ),
              ),
            ),
            PositionedDirectional(
              top: 0,
              bottom: 0,
              end: -(1 - t) * _panelWidth,
              width: _panelWidth,
              child: panel!,
            ),
          ],
        );
      },
      child: BlockSemantics(
        // Outside the page's Scaffold: without a text style of its own the
        // panel's labels fall back to the debug underline.
        child: DefaultTextStyle(
         style: HollowTypography.body.copyWith(color: hollow.textPrimary),
         child: _PanelSurface(
          serverId: widget.serverId,
          onClose: close,
          onDragStart: _beginDrag,
          onDragUpdate: (dx) => _dragBy(closing(dx)),
          onDragEnd: (v) => _release(closing(v) / _panelWidth),
         ),
        ),
      ),
    );
  }
}

/// A drag coming from the chat page: page widths in, panel progress out.
class _PanelDrive extends HollowSwipeDrive {
  final MobileMemberSidePanelState panel;

  _PanelDrive(this.panel);

  @override
  void update(double delta) {
    if (panel.mounted) panel._dragBy(delta * panel._pageWidth);
  }

  @override
  void end(double velocity) {
    if (!panel.mounted) return;
    panel._release(velocity * panel._pageWidth / panel._panelWidth);
  }
}

class _PanelSurface extends StatelessWidget {
  final String serverId;
  final VoidCallback onClose;

  final VoidCallback onDragStart;

  /// Physical horizontal pixels moved, and the release velocity in px/s.
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;

  const _PanelSurface({
    required this.serverId,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final padding = MediaQuery.paddingOf(context);
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<
            HorizontalDragGestureRecognizer>(
          () => HorizontalDragGestureRecognizer(debugOwner: this),
          (r) {
            r.onStart = (_) => onDragStart();
            r.onUpdate = (d) => onDragUpdate(d.primaryDelta!);
            r.onEnd = (d) => onDragEnd(d.velocity.pixelsPerSecond.dx);
          },
        ),
      },
      child: Container(
        decoration: BoxDecoration(
          color: hollow.overlay,
          border: BorderDirectional(start: BorderSide(color: hollow.border)),
          boxShadow: HollowShadows.float,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: padding.top),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                  HollowSpacing.lg, HollowSpacing.xs, HollowSpacing.xs, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Members',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.subheading
                            .copyWith(color: hollow.textPrimary),
                      ),
                    ),
                  ),
                  HollowIconButton(
                    icon: LucideIcons.x,
                    label: 'Close members',
                    size: 44,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Expanded(
              child: MemberList(
                serverId: serverId,
                touch: true,
                bottomInset: padding.bottom + HollowSpacing.lg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
