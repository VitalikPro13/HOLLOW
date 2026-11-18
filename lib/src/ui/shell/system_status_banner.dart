import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';

/// Visual mapping for a [StatusLevel], shared by the global banner and the Home
/// status line so the two cannot drift.
///
/// `info` is the quiet grey: not the accent, which marks what acts, and apart
/// from the amber alarm levels and the red critical one, so a neutral note
/// never reads as an incident.
({Color color, IconData icon}) statusVisual(
    StatusLevel level, HollowTheme hollow) {
  switch (level) {
    case StatusLevel.operational:
      return (color: hollow.success, icon: LucideIcons.circleCheck);
    case StatusLevel.info:
      return (color: hollow.textSecondary, icon: LucideIcons.info);
    case StatusLevel.maintenance:
      return (color: hollow.warning, icon: LucideIcons.wrench);
    case StatusLevel.warning:
      return (color: hollow.warning, icon: LucideIcons.triangleAlert);
    case StatusLevel.critical:
      return (color: hollow.error, icon: LucideIcons.octagonAlert);
  }
}

/// A signed feed's link is still someone else's string, so it shows only when it
/// is one the untrusted link helper would actually open.
bool _hasOpenableLink(SystemStatus status) => canOpenUntrustedUrl(status.link);

void _openStatusLink(String url) {
  openUntrustedUrl(url).catchError((_) => false);
}

/// The countdown text for [d] left: "5d 10h" from 48 hours on, "2h 14m" above
/// an hour, "14:23" under an hour, "45s" in the last minute.
String formatStatusCountdown(Duration d) {
  if (d.inHours >= 48) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes >= 1) {
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
  return '${d.inSeconds}s';
}

/// Whether [formatStatusCountdown] changes every second at [d]. Only then are
/// tabular figures worth it: Onest's tabular "1" is a full digit wide, which
/// reads as a gap in a static "1 30h".
bool countdownTicksEachSecond(Duration d) => d.inHours < 1;

/// A live, self-ticking countdown to an absolute UTC instant.
///
/// Once the target passes it flips to "In progress now" and stops ticking: for
/// maintenance that is the moment users most need it, so the notice stays until
/// the author clears status.json. Pure text, so it is reduce-motion-safe.
class StatusCountdown extends StatefulWidget {
  final DateTime until; // UTC
  final String label;
  final Color color;

  const StatusCountdown({
    super.key,
    required this.until,
    required this.label,
    required this.color,
  });

  /// The clock glyph matches the caption it sits beside.
  static const double _iconSize = 11;

  @override
  State<StatusCountdown> createState() => _StatusCountdownState();
}

class _StatusCountdownState extends State<StatusCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(StatusCountdown old) {
    super.didUpdateWidget(old);
    if (old.until != widget.until) {
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    // Only ticks while the target is in the future; past it the label is
    // static, so no timer is needed.
    if (DateTime.now().toUtc().isBefore(widget.until)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!DateTime.now().toUtc().isBefore(widget.until)) {
          _timer?.cancel();
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final remaining = widget.until.difference(now);
    final expired = remaining.isNegative || remaining == Duration.zero;

    final String text;
    if (expired) {
      text = 'In progress now';
    } else {
      final label = widget.label.isNotEmpty ? widget.label : 'In';
      text = '$label ${formatStatusCountdown(remaining)}';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.clock,
            size: StatusCountdown._iconSize, color: widget.color),
        const SizedBox(width: HollowSpacing.xs),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.caption.copyWith(
              color: widget.color,
              fontWeight: FontWeight.w600,
              fontFeatures: !expired && countdownTicksEachSecond(remaining)
                  ? const [FontFeature.tabularFigures()]
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// Which edge the banner's divider sits on: below it on desktop, above it on
/// mobile so it reads as separate from the bar beneath.
enum StatusBannerAnchor { top, bottom }

/// The global, dismissible system-status strip. Renders ONLY for banner-worthy,
/// non-dismissed notices, so an operational feed collapses it to nothing. With
/// several live notices it shows the most severe one not yet dismissed.
///
/// Starts collapsed, because the notice appears unprompted and should announce
/// itself quietly: one line on desktop (title, a preview of the message, the
/// countdown and the link), the title over the countdown on a phone. Expanding
/// only ADDS the message below, at a readable line length; nothing already on
/// screen moves. The X dismisses without toggling, and a new notice id resets.
class SystemStatusBanner extends ConsumerStatefulWidget {
  /// Which edge carries the divider line.
  final StatusBannerAnchor anchor;

  const SystemStatusBanner({super.key, this.anchor = StatusBannerAnchor.top});

  @override
  ConsumerState<SystemStatusBanner> createState() => _SystemStatusBannerState();
}

class _SystemStatusBannerState extends ConsumerState<SystemStatusBanner> {
  bool _expanded = false;
  String _lastId = '';

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(statusProvider.select((s) => s.bannerNotice));
    if (status == null) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final vis = statusVisual(status.level, hollow);
    final color = vis.color;

    // A fresh notice re-announces quietly, so a new id resets to collapsed.
    if (status.id != _lastId) {
      _lastId = status.id;
      _expanded = false;
    }

    final headline = status.title.isNotEmpty ? status.title : status.message;
    // A message is the detail: under a title it is the body, alone it is the
    // headline, truncated until expanded.
    final hasDetail = status.message.isNotEmpty;
    final hasBody = status.title.isNotEmpty && status.message.isNotEmpty;
    final open = _expanded && hasDetail;

    final divider = BorderSide(color: hollow.border);
    void toggle() => setState(() => _expanded = !_expanded);

    final banner = Semantics(
      container: true,
      liveRegion: true,
      label: 'System status: $headline',
      child: GestureDetector(
        // Tapping the bar toggles expansion, when there is detail to show.
        behavior: HitTestBehavior.opaque,
        onTap: hasDetail ? toggle : null,
        child: MouseRegion(
          cursor: hasDetail ? SystemMouseCursors.click : MouseCursor.defer,
          child: AnimatedSize(
            duration: HollowDurations.fast,
            curve: HollowCurves.subtle,
            alignment: Alignment.topCenter,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // Tinted CHROME, not a translucent wash: over a wallpaper a
                // translucent fill lets the image straight through and the bar
                // stops looking like part of the app (issue #54).
                color: hollow.noticeSurface(color),
                border: Border(
                  top: widget.anchor == StatusBannerAnchor.bottom
                      ? divider
                      : BorderSide.none,
                  bottom: widget.anchor == StatusBannerAnchor.top
                      ? divider
                      : BorderSide.none,
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: LayoutBuilder(builder: (context, constraints) {
                  final parts = _BannerParts(
                    status: status,
                    hollow: hollow,
                    color: color,
                    icon: vis.icon,
                    headline: headline,
                    hasDetail: hasDetail,
                    hasBody: hasBody,
                    open: open,
                    touch: constraints.maxWidth < _kPhoneBelow,
                    onToggle: toggle,
                    onDismiss: () =>
                        ref.read(statusProvider.notifier).dismiss(status.id),
                  );
                  return parts.touch ? parts.phone() : parts.desktop();
                }),
              ),
            ),
          ),
        ),
      ),
    );
    // A toast rises above the strip rather than hiding the notice (the phone
    // carries it at the bottom, where toasts land).
    return ToastKeepClear(child: banner);
  }
}

/// Below this width the banner takes its phone layout and touch-sized controls
/// (the mobile shell, phone or narrow window).
const double _kPhoneBelow = 600;

/// The longest line the message runs to on a wide window: a paragraph across
/// 2500 px is unreadable.
const double _kProseMaxWidth = 640;

const double _kIcon = 16;

/// The pieces both banner layouts share.
class _BannerParts {
  _BannerParts({
    required this.status,
    required this.hollow,
    required this.color,
    required this.icon,
    required this.headline,
    required this.hasDetail,
    required this.hasBody,
    required this.open,
    required this.touch,
    required this.onToggle,
    required this.onDismiss,
  });

  final SystemStatus status;
  final HollowTheme hollow;
  final Color color;
  final IconData icon;
  final String headline;
  final bool hasDetail;
  final bool hasBody;
  final bool open;
  final bool touch;
  final VoidCallback onToggle;
  final VoidCallback onDismiss;

  double get _control => touch ? 44 : 32;

  /// Under the headline, past the icon and its gap.
  static const _indent = _kIcon + HollowSpacing.sm;

  TextStyle get _titleStyle => HollowTypography.label
      .copyWith(color: hollow.textPrimary, fontWeight: FontWeight.w600);

  Widget get _icon => Icon(icon, size: _kIcon, color: color);

  /// The height of the strip's first line: the controls and the link button
  /// centre on it, and so does the first line of text beside them.
  double get _line => touch ? 44 : 34;

  bool get _hasTitle => status.title.isNotEmpty;

  /// Top and bottom inset that centres one line of [style] on [_line].
  EdgeInsetsDirectional _lineInset(TextStyle style) {
    final inset = (_line - style.fontSize! * (style.height ?? 1)) / 2;
    return EdgeInsetsDirectional.only(top: inset, bottom: inset);
  }

  /// The title. Collapsed it is clipped to [maxLines] only when expanding
  /// shows the rest; with nothing to expand it wraps in full.
  Widget _title({int? maxLines}) {
    final clip = !open && hasDetail;
    return Text(
      headline,
      maxLines: clip ? maxLines : null,
      overflow: clip ? TextOverflow.ellipsis : null,
      style: _titleStyle,
    );
  }

  /// The message in the primary text tier: the notice is the one thing the
  /// strip says, so its body is not faded into the amber.
  TextStyle get _bodyStyle => HollowTypography.bodySmall
      .copyWith(color: hollow.textPrimary, height: 1.45);

  Widget get _body => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kProseMaxWidth),
        child: Text(status.message, style: _bodyStyle),
      );

  Widget? get _countdown => status.until == null
      ? null
      : StatusCountdown(
          until: status.until!,
          label: status.untilLabel,
          color: color,
        );

  /// The notice's one action. A signed feed's link is still someone else's
  /// string, so it shows only when the untrusted link helper would open it.
  Widget? get _link => _hasOpenableLink(status)
      ? HollowButton.outline(
          compact: !touch,
          touch: touch,
          onPressed: () => _openStatusLink(status.link),
          child: Text(
            status.linkLabel.isNotEmpty ? status.linkLabel : 'Details',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        )
      : null;

  List<Widget> get _controls => [
        if (hasDetail)
          HollowIconButton(
            icon: open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
            label: open ? 'Show less' : 'Show the whole notice',
            size: _control,
            onPressed: onToggle,
          ),
        if (hasDetail && status.dismissible)
          const SizedBox(width: HollowSpacing.xs),
        if (status.dismissible)
          HollowIconButton(
            icon: LucideIcons.x,
            label: 'Dismiss status notice',
            size: _control,
            onPressed: onDismiss,
          ),
      ];

  /// The first line's text: the title, or the message itself when the notice
  /// has no title, which reads as a body once open.
  Widget _headText({required int collapsedLines}) {
    if (!_hasTitle && open) {
      return Padding(padding: _lineInset(_bodyStyle), child: _body);
    }
    return Padding(
      padding: _lineInset(_titleStyle),
      child: _title(maxLines: collapsedLines),
    );
  }

  /// One line: icon, title, a preview of the message, then the countdown, the
  /// link and the controls on the trailing edge. Open, the message follows
  /// below at a readable width; the first line only grows when its text wraps.
  Widget desktop() {
    final countdown = _countdown;
    final link = _link;
    // Collapsed, the message trails the title on the same line and gives way
    // first: one span, so the title keeps its whole width before any preview.
    final Widget head = hasBody && !open
        ? Padding(
            padding: _lineInset(_titleStyle),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: headline, style: _titleStyle),
                const WidgetSpan(child: SizedBox(width: HollowSpacing.md)),
                TextSpan(
                  text: status.message,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          )
        : _headText(collapsedLines: 1);
    final trailing = [
      if (countdown != null) ...[
        const SizedBox(width: HollowSpacing.md),
        countdown,
      ],
      if (link != null) ...[
        const SizedBox(width: HollowSpacing.md),
        link,
      ],
      if (_controls.isNotEmpty) ...[
        const SizedBox(width: HollowSpacing.sm),
        ..._controls,
      ],
    ];
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        HollowSpacing.lg,
        HollowSpacing.sm,
        HollowSpacing.sm,
        HollowSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: _line, child: Center(child: _icon)),
              const SizedBox(width: HollowSpacing.sm),
              // Loose, so the message's 640 px cap holds inside the row.
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: head,
                ),
              ),
              SizedBox(
                height: _line,
                child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
              ),
            ],
          ),
          // Under the whole first line, not beside the trailing controls, so
          // a narrow window still gives the message its full measure.
          if (open && hasBody)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: _indent),
              child: _body,
            ),
        ],
      ),
    );
  }

  /// The title (two lines at most while there is more to show) over the
  /// countdown, the controls beside them. Open adds the message below, at the
  /// title's edge; the link shows once open, or at once when there is nothing
  /// to expand.
  Widget phone() {
    final countdown = _countdown;
    final link = open || !hasDetail ? _link : null;
    final below = open && hasBody;
    return Padding(
      // The 44 px controls carry their own inset, so the X's glyph sits as
      // far from the end edge as the level icon from the start.
      padding: EdgeInsetsDirectional.fromSTEB(
        HollowSpacing.lg,
        HollowSpacing.xs,
        HollowSpacing.xs,
        below || link != null ? HollowSpacing.md : HollowSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: _line),
            child: Row(
              children: [
                _icon,
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_hasTitle && open) _body else _title(maxLines: 2),
                      if (countdown != null) ...[
                        const SizedBox(height: HollowSpacing.xxs),
                        countdown,
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: HollowSpacing.xs),
                ..._controls,
              ],
            ),
          ),
          if (below || link != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(
                top: HollowSpacing.xs,
                start: _indent,
                end: HollowSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (below) _body,
                  if (below && link != null)
                    const SizedBox(height: HollowSpacing.md),
                  ?link,
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The calm Home-dashboard status line.
///
/// Unlike the banner it renders the healthy state too: Home is a low-traffic
/// surface you deliberately land on, so a reassuring line is welcome rather than
/// nagging. Tap-to-expand mirrors the banner. The healthy state has no detail,
/// so it stays a plain non-interactive line, out of the focus chain.
class HomeStatusCard extends ConsumerStatefulWidget {
  const HomeStatusCard({super.key});

  @override
  ConsumerState<HomeStatusCard> createState() => _HomeStatusCardState();
}

class _HomeStatusCardState extends ConsumerState<HomeStatusCard> {
  bool _expanded = false;
  String _lastId = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final st = ref.watch(statusProvider);
    final status = st.status;

    // Healthy until the first fetch resolves, so no empty box flickers.
    final vis = statusVisual(status.level, hollow);
    final color = vis.color;

    final bool operational = status.level == StatusLevel.operational;
    final String headline = operational
        ? 'All systems operational'
        : (status.title.isNotEmpty ? status.title : status.message);
    final String? sub = operational
        ? null
        : (status.title.isNotEmpty && status.message.isNotEmpty
            ? status.message
            : null);

    // A fresh notice re-announces quietly, so a new id resets to collapsed.
    if (status.id != _lastId) {
      _lastId = status.id;
      _expanded = false;
    }

    // Only worth a tap when the collapsed card actually hides something.
    final bool hasLink = _hasOpenableLink(status);
    final bool hasDetail =
        !operational && (status.message.isNotEmpty || hasLink);
    final bool showFull = _expanded && hasDetail;

    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: operational ? hollow.elevated : hollow.noticeSurface(color, alpha: 0.10),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(
          color: operational ? hollow.border : color.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xxs),
            child: Icon(vis.icon, size: 14, color: color),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'System status',
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  headline,
                  maxLines: showFull ? null : 2,
                  overflow:
                      showFull ? TextOverflow.clip : TextOverflow.ellipsis,
                  style: HollowTypography.caption.copyWith(color: color),
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: showFull ? null : 2,
                    overflow:
                        showFull ? TextOverflow.clip : TextOverflow.ellipsis,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      height: showFull ? 1.35 : null,
                    ),
                  ),
                if (status.until != null) ...[
                  const SizedBox(height: HollowSpacing.xxs),
                  StatusCountdown(
                    until: status.until!,
                    label: status.untilLabel,
                    color: color,
                  ),
                ],
                // Expand-only: an underlined link in a glanceable summary would
                // compete with the tap-to-expand affordance.
                if (showFull && hasLink) ...[
                  const SizedBox(height: HollowSpacing.xs),
                  HollowFocusRing(
                    enabled: true,
                    onActivate: () => _openStatusLink(status.link),
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    child: GestureDetector(
                      // Absorbed so following the link does not also collapse
                      // the card out from under the user.
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openStatusLink(status.link),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Semantics(
                          button: true,
                          label: status.linkLabel.isNotEmpty
                              ? status.linkLabel
                              : 'Details',
                          child: Text(
                            status.linkLabel.isNotEmpty
                                ? status.linkLabel
                                : 'Details',
                            style: HollowTypography.caption.copyWith(
                              color: color,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline,
                              decorationColor: color,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasDetail) ...[
            const SizedBox(width: HollowSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.xxs),
              child: Icon(
                showFull ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 14,
                color: color.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );

    final animated = AnimatedSize(
      duration: HollowDurations.fast,
      curve: HollowCurves.subtle,
      alignment: Alignment.topCenter,
      child: card,
    );

    // The healthy state carries no detail, so it stays a plain inert line
    // rather than a control that expands into nothing.
    if (!hasDetail) {
      return Semantics(
        container: true,
        label: 'System status: $headline',
        child: animated,
      );
    }

    void toggle() => setState(() => _expanded = !_expanded);

    return Semantics(
      container: true,
      button: true,
      label: 'System status: $headline',
      hint: showFull ? 'Collapse notice' : 'Expand notice',
      child: HollowFocusRing(
        enabled: true,
        onActivate: toggle,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: toggle,
            child: animated,
          ),
        ),
      ),
    );
  }
}
