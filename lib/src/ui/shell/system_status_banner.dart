import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

/// Visual mapping for a [StatusLevel], shared by the global banner and the Home
/// status line so the two cannot drift.
///
/// There is no info theme token, so `info` reuses the app accent: distinct from
/// the amber alarm levels and the red critical one, which keeps a neutral note
/// from reading as an incident.
({Color color, IconData icon}) statusVisual(
    StatusLevel level, HollowTheme hollow) {
  switch (level) {
    case StatusLevel.operational:
      return (color: hollow.success, icon: LucideIcons.circleCheck);
    case StatusLevel.info:
      return (color: hollow.accentText, icon: LucideIcons.info);
    case StatusLevel.maintenance:
      return (color: hollow.warning, icon: LucideIcons.wrench);
    case StatusLevel.warning:
      return (color: hollow.warning, icon: LucideIcons.triangleAlert);
    case StatusLevel.critical:
      return (color: hollow.error, icon: LucideIcons.octagonAlert);
  }
}

/// A live, self-ticking countdown to an absolute UTC instant.
///
/// Once the target passes it flips to "In progress now" and stops ticking: for
/// maintenance that is the moment users most need it, so the notice stays until
/// the author clears status.json. Pure text, so it is reduce-motion-safe.
class StatusCountdown extends StatefulWidget {
  final DateTime until; // UTC
  final String label;
  final Color color;
  final double fontSize;

  const StatusCountdown({
    super.key,
    required this.until,
    required this.label,
    required this.color,
    this.fontSize = 11,
  });

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

  /// "2h 14m" above an hour, "14:23" under an hour, "45s" in the last minute.
  String _fmt(Duration d) {
    if (d.inHours >= 1) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      return '${h}h ${m}m';
    }
    if (d.inMinutes >= 1) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '$m:${s.toString().padLeft(2, '0')}';
    }
    return '${d.inSeconds}s';
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
      text = '$label ${_fmt(remaining)}';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.clock, size: widget.fontSize, color: widget.color),
        const SizedBox(width: 4),
        Text(
          text,
          style: HollowTypography.caption.copyWith(
            color: widget.color,
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w600,
            // Tabular figures stop the countdown jittering as digits change.
            fontFeatures: const [FontFeature.tabularFigures()],
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
/// non-dismissed notices, so an operational feed collapses it to nothing.
///
/// Starts collapsed, because the notice appears unprompted and should announce
/// itself quietly; tapping expands to the full untruncated text, which on a
/// narrow phone is the difference between a notice and an ellipsis. The X
/// dismisses without toggling expansion, and a new notice id resets it.
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

  void _openLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(statusProvider);
    if (!st.showBanner) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final status = st.status;
    final vis = statusVisual(status.level, hollow);
    final color = vis.color;

    // A fresh notice re-announces quietly, so a new id resets to collapsed.
    if (status.id != _lastId) {
      _lastId = status.id;
      _expanded = false;
    }

    final headline = status.title.isNotEmpty ? status.title : status.message;
    // Only worth a tap when there is truncatable detail to show.
    final hasDetail = status.message.isNotEmpty;

    final divider = BorderSide(color: hollow.border.withValues(alpha: 0.3));

    final dismissBtn = status.dismissible
        ? HollowFocusRing(
            enabled: true,
            onActivate: () =>
                ref.read(statusProvider.notifier).dismissCurrent(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: GestureDetector(
              // Absorbed so dismissing does not also toggle expansion.
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(statusProvider.notifier).dismissCurrent(),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Semantics(
                  button: true,
                  label: 'Dismiss status notice',
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(LucideIcons.x,
                        size: 14, color: color.withValues(alpha: 0.8)),
                  ),
                ),
              ),
            ),
          )
        : null;

    final chevron = hasDetail
        ? Icon(
            _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
            size: 15,
            color: color.withValues(alpha: 0.7),
          )
        : null;

    final detailsLink = status.link.isNotEmpty
        ? HollowFocusRing(
            enabled: true,
            onActivate: () => _openLink(status.link),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openLink(status.link),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Semantics(
                  button: true,
                  label: status.linkLabel.isNotEmpty
                      ? status.linkLabel
                      : 'Details',
                  child: Text(
                    status.linkLabel.isNotEmpty ? status.linkLabel : 'Details',
                    style: HollowTypography.caption.copyWith(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                      decorationColor: color,
                    ),
                  ),
                ),
              ),
            ),
          )
        : null;

    final countdown = status.until != null
        ? StatusCountdown(
            until: status.until!,
            label: status.untilLabel,
            color: color,
          )
        : null;

    Widget collapsed = Row(
      children: [
        Icon(vis.icon, size: 15, color: color),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.body.copyWith(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (status.title.isNotEmpty && status.message.isNotEmpty) ...[
                const SizedBox(width: HollowSpacing.sm),
                Container(
                  width: 3,
                  height: 3,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Flexible(
                  child: Text(
                    status.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.caption.copyWith(
                      color: color.withValues(alpha: 0.9),
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (countdown != null) ...[
          const SizedBox(width: HollowSpacing.md),
          countdown,
        ],
        if (chevron != null) ...[
          const SizedBox(width: HollowSpacing.sm),
          chevron,
        ],
        if (dismissBtn != null) ...[
          const SizedBox(width: HollowSpacing.xs),
          dismissBtn,
        ],
      ],
    );

    Widget expanded = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(vis.icon, size: 15, color: color),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                headline,
                style: HollowTypography.body.copyWith(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (chevron != null) ...[
              const SizedBox(width: HollowSpacing.sm),
              chevron,
            ],
            if (dismissBtn != null) ...[
              const SizedBox(width: HollowSpacing.xs),
              dismissBtn,
            ],
          ],
        ),
        // Full message, no truncation: the whole point of expanding.
        if (status.title.isNotEmpty && status.message.isNotEmpty) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 23),
            child: Text(
              status.message,
              style: HollowTypography.caption.copyWith(
                color: color.withValues(alpha: 0.95),
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ],
        if (countdown != null || detailsLink != null) ...[
          const SizedBox(height: 7),
          Padding(
            padding: const EdgeInsets.only(left: 23),
            child: Row(
              children: [
                ?countdown,
                if (countdown != null && detailsLink != null)
                  const SizedBox(width: HollowSpacing.md),
                ?detailsLink,
              ],
            ),
          ),
        ],
      ],
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: 'System status: $headline',
      child: GestureDetector(
        // Tapping the bar toggles expansion, when there is detail to show.
        behavior: HitTestBehavior.opaque,
        onTap: hasDetail ? () => setState(() => _expanded = !_expanded) : null,
        child: AnimatedSize(
          duration: HollowDurations.fast,
          curve: HollowCurves.subtle,
          alignment: Alignment.topCenter,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: 9,
            ),
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
            child: _expanded && hasDetail ? expanded : collapsed,
          ),
        ),
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

  void _openLink(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

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
    final bool hasDetail =
        !operational && (status.message.isNotEmpty || status.link.isNotEmpty);
    final bool showFull = _expanded && hasDetail;

    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: operational ? hollow.surface : hollow.noticeSurface(color, alpha: 0.10),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(
          color: operational ? hollow.border : color.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(vis.icon, size: 14, color: color),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'System Status',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  headline,
                  maxLines: showFull ? null : 2,
                  overflow:
                      showFull ? TextOverflow.clip : TextOverflow.ellipsis,
                  style: HollowTypography.caption.copyWith(
                    color: color,
                    fontSize: 10,
                  ),
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: showFull ? null : 2,
                    overflow:
                        showFull ? TextOverflow.clip : TextOverflow.ellipsis,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 10,
                      height: showFull ? 1.35 : null,
                    ),
                  ),
                if (status.until != null) ...[
                  const SizedBox(height: 3),
                  StatusCountdown(
                    until: status.until!,
                    label: status.untilLabel,
                    color: color,
                    fontSize: 10,
                  ),
                ],
                // Expand-only: an underlined link in a glanceable summary would
                // compete with the tap-to-expand affordance.
                if (showFull && status.link.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  HollowFocusRing(
                    enabled: true,
                    onActivate: () => _openLink(status.link),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    child: GestureDetector(
                      // Absorbed so following the link does not also collapse
                      // the card out from under the user.
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openLink(status.link),
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
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
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
              padding: const EdgeInsets.only(top: 1),
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
