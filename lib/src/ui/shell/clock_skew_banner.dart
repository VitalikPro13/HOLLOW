import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/providers/clock_skew_provider.dart';
import 'package:hollow/src/core/services/date_time_settings.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';

/// Narrower than this, the button sits under the words.
const double _stackBelow = 520;

const double _kIcon = 16;

/// The headline: how far the device clock is off, and which way.
String clockSkewHeadline(int offsetSecs) {
  final way = offsetSecs > 0 ? 'behind' : 'ahead';
  return 'Your device clock is ${clockSkewAmount(offsetSecs)} $way';
}

/// What the person should know and do, for the level, the way the clock is off and
/// this platform. Ahead, peers refuse what we send and we drop their live signals as
/// stale; behind, the reverse.
String clockSkewDetail(ClockSkewLevel level,
    {required int offsetSecs, required bool canOpen, required bool ios}) {
  final ahead = offsetSecs < 0;
  final what = level != ClockSkewLevel.urgent
      ? 'Some relays refuse to connect while it is off.'
      : ahead
          ? 'Others may not get your messages, and you may miss their calls.'
          : 'You may not get messages from others, and they may miss your calls.';
  if (canOpen) return '$what Set the time to update automatically.';
  if (ios) return '$what Turn on Set Automatically in Settings, General, Date & Time.';
  return '$what Turn on automatic time in your system settings.';
}

/// A strip under the status banner while the relay says our clock is off; it
/// never blocks anything and goes away by itself once the clock is right.
class ClockSkewBanner extends ConsumerWidget {
  final StatusBannerAnchor anchor;

  const ClockSkewBanner({super.key, this.anchor = StatusBannerAnchor.top});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skew = ref.watch(clockSkewProvider);
    final offset = skew.offsetSecs;
    if (!skew.visible || offset == null) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final urgent = skew.level == ClockSkewLevel.urgent;
    final color = urgent ? hollow.error : hollow.warning;
    final canOpen = canOpenDateTimeSettings;
    final headline = clockSkewHeadline(offset);
    final detail = clockSkewDetail(
      skew.level,
      offsetSecs: offset,
      canOpen: canOpen,
      ios: !kIsWeb && Platform.isIOS,
    );
    final divider = BorderSide(color: hollow.border);
    final phone = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    final open = canOpen
        ? HollowButton.outline(
            compact: true,
            touch: phone,
            onPressed: () => openDateTimeSettings().catchError((_) => false),
            child: const Text('Open time settings'),
          )
        : null;
    // Only the milder warning can be put away; past four minutes it stays.
    final dismiss = urgent
        ? null
        : HollowIconButton(
            icon: LucideIcons.x,
            label: 'Dismiss clock warning',
            size: phone ? 44 : 24,
            onPressed: () => ref.read(clockSkewProvider.notifier).dismiss(),
          );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(headline, style: HollowTypography.label.copyWith(color: color)),
        Text(
          detail,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
        ),
      ],
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: '$headline. $detail',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.noticeSurface(color),
          border: Border(
            top: anchor == StatusBannerAnchor.bottom ? divider : BorderSide.none,
            bottom: anchor == StatusBannerAnchor.top ? divider : BorderSide.none,
          ),
        ),
        child: LayoutBuilder(builder: (context, box) {
          // On a phone the button goes under the words, which keep the width.
          final stacked = open != null && box.maxWidth < _stackBelow;
          final row = Row(
            children: [
              Icon(LucideIcons.clockAlert, size: _kIcon, color: color),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(child: text),
              if (open != null && !stacked) ...[
                const SizedBox(width: HollowSpacing.md),
                open,
              ],
              if (dismiss != null) ...[
                const SizedBox(width: HollowSpacing.xs),
                dismiss,
              ],
            ],
          );
          if (!stacked) return row;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              row,
              const SizedBox(height: HollowSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(left: _kIcon + HollowSpacing.sm),
                child: open,
              ),
            ],
          );
        }),
      ),
    );
  }
}
