import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

final _mediaThemes = <int, HollowTheme>{};

/// Colours for anything drawn over live video. A scrim over a picture is dark
/// in both app themes, so names and warnings there are measured against the
/// dark ladder: a light theme's dark name colours vanish on it.
HollowTheme callMediaTheme(HollowTheme hollow) =>
    _mediaThemes[hollow.accent.toARGB32()] ??= HollowTheme.dark()
        .copyWithAccent(hollow.accent, hollow.accentHover, hollow.accentMuted);

/// A person's colour in a call, for names: yours is always the accent.
Color callNameColor(HollowTheme hollow,
        {required bool isSelf, required String master}) =>
    isSelf ? hollow.accentText : nameColorFor(master, hollow);

/// The speaking ring's colour: the accent fill for you, the person's own name
/// colour for everyone else. [master] must be the MASTER id, or one person's
/// devices ring in different colours.
Color callRingColor(HollowTheme hollow,
        {required bool isSelf, required String master}) =>
    isSelf ? hollow.accent : nameColorFor(master, hollow);

/// Stage metrics shared by the tiles and the layout.
abstract final class CallMetrics {
  static const double stripTileWidth = 132;
  static const double stripTileHeight = 76;
  static const double compactAvatar = 32;
  static const double stripAvatar = 30;
  static const double barButton = 40;
  static const double leaveWidth = 48;

  /// What the floating bar takes off the stage's bottom edge.
  static const double barReserve = HollowSpacing.lg * 2 + barButton +
      HollowSpacing.xs * 2 + 2;

  /// Room the ring needs outside a tile: stroke plus gap.
  static const double ringOutset = 4;
}

/// A label or control laid over video: the dark media scrim, white text.
class CallMediaLabel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const CallMediaLabel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
      horizontal: HollowSpacing.sm,
      vertical: HollowSpacing.xs,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: HollowColors.mediaScrim,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Padding(
        padding: padding,
        child: DefaultTextStyle.merge(
          style: HollowTypography.label.copyWith(color: HollowColors.onMedia),
          child: IconTheme.merge(
            data: const IconThemeData(color: HollowColors.onMedia, size: 14),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// "1080p60" as the stage writes it, "1080p · 60".
String callQualityText(String label) {
  final m = RegExp(r'^(\d+p|4K)(\d+)?$').firstMatch(label);
  if (m == null) return label;
  final fps = m.group(2);
  return fps == null ? m.group(1)! : '${m.group(1)} · $fps';
}
