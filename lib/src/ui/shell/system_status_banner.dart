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

/// Visual mapping for a [StatusLevel] — the single source of truth shared by
/// the global banner and the Home status line so both stay consistent.
///
/// There is no dedicated blue/info theme token, so `info` reuses the app accent
/// (teal): visually distinct from the amber alarm levels and the red critical
/// one, which is what keeps a neutral/playful "info" note from reading as an
/// incident.
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
/// Renders `<label> <remaining>` (e.g. "Starts in 14:23"). When the target
/// passes it flips to "In progress now" and stops ticking — for maintenance
/// that's the moment users most need to know it's happening NOW, so the notice
/// stays (the author clears status.json when the work is done).
///
/// Pure text, so it is inherently reduce-motion-safe. One [Timer.periodic] that
/// is cancelled on dispose; it re-bases when the target changes.
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
    // Only tick while the target is still in the future; once it passes the
    // label is static ("In progress"), so no timer is needed.
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
            // Tabular figures keep the countdown from jittering as digits change.
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Which edge the banner's divider sits on. Desktop mounts it as a top-strip
/// (divider BELOW it); mobile bottom-anchors it above the nav/input bar
/// (divider ABOVE it) so it reads as separate from the bar beneath.
enum StatusBannerAnchor { top, bottom }

/// The global, dismissible system-status strip. Desktop mounts it directly
/// under the always-visible Friends bar (anchor: top); mobile bottom-anchors it
/// above the nav bar / chat input / under the call-sheet name (anchor: bottom).
/// Renders ONLY for banner-worthy, non-dismissed notices — when the feed is
/// operational/empty it collapses to nothing (silence = healthy).
///
/// Tap-to-expand: collapsed it's a compact one-liner (title + message ellipsised
/// — which on a narrow phone truncates both to near-nothing), so tapping the bar
/// expands it to the FULL untruncated title + wrapped message. Starts collapsed
/// (the notice appears unprompted, so it should announce itself quietly and let
/// the user opt into the detail) with a chevron hint that there's more. The X
/// dismisses without toggling expansion; a new notice id resets to collapsed.
class SystemStatusBanner extends ConsumerStatefulWidget {
  /// Which edge carries the divider line. [StatusBannerAnchor.top] = the banner
  /// is itself at the top of a region, divider below (desktop). `.bottom` = the
  /// banner sits just above a bar, divider above it (mobile).
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

    // A fresh notice re-announces quietly: reset to collapsed when the id flips.
    if (status.id != _lastId) {
      _lastId = status.id;
      _expanded = false;
    }

    // Headline: prefer the title, fall back to the message if title is empty.
    final headline = status.title.isNotEmpty ? status.title : status.message;
    // Only worth a tap if there's truncatable detail (a message AND a title, or
    // a long message). Keep it simple: expandable whenever a message exists.
    final hasDetail = status.message.isNotEmpty;

    final divider = BorderSide(color: hollow.border.withValues(alpha: 0.3));

    final dismissBtn = status.dismissible
        ? HollowFocusRing(
            enabled: true,
            onActivate: () =>
                ref.read(statusProvider.notifier).dismissCurrent(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: GestureDetector(
              // Absorb the tap so dismissing doesn't also toggle expansion.
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

    // ── Collapsed: compact single line (icon · headline · message… · time · ⌄ · ✕)
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

    // ── Expanded: full title + wrapped message, then countdown + Details row.
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
        // Full message, no truncation — the whole point of expanding.
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
        // Tapping the bar toggles expansion (only when there's detail to show).
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
              color: color.withValues(alpha: 0.10),
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

/// The calm Home-dashboard status line that REPLACES the Recovery Phrase card.
/// Unlike the banner, this renders the healthy "All systems operational" green
/// state too — Home is a low-traffic surface you deliberately land on, so a
/// reassuring steady-state line is welcome rather than nagging. For
/// info/maintenance/warning/critical it shows the same colour + headline +
/// countdown as the banner.
class HomeStatusCard extends ConsumerWidget {
  const HomeStatusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final st = ref.watch(statusProvider);
    final status = st.status;

    // Before the first fetch resolves, assume healthy (don't flicker an empty
    // box). After fetch, an empty/operational feed shows the green line.
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: operational ? hollow.surface : color.withValues(alpha: 0.08),
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.caption.copyWith(
                    color: color,
                    fontSize: 10,
                  ),
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 10,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
