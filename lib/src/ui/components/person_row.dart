import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// One person in a people list: their avatar with its presence dot, their
/// name, and the small marks they have earned after it.
///
/// The one row for this kind of thing (design language 5.3, check 8): the
/// member panel and the phone's member sheet draw a person with this.
class PersonRow extends StatelessWidget {
  final String peerId;
  final String name;
  final bool online;

  /// Glyphs after the name (a support mark, a verified Twitch account).
  final List<Widget> nameTrailing;

  /// One quiet line under the name, only when there is something to say (the
  /// status line they set).
  final String? subtitle;

  final VoidCallback onTap;

  /// Phone metrics (design language 5.4): a larger avatar, type one step up,
  /// full bleed and at least 48 tall.
  final bool touch;

  const PersonRow({
    super.key,
    required this.peerId,
    required this.name,
    required this.online,
    required this.onTap,
    this.nameTrailing = const [],
    this.subtitle,
    this.touch = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = touch ? HollowTypography.bodyTouch : HollowTypography.body;
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      semanticButton: false,
      semanticLabel: [name, if (!online) 'offline', ?subtitle].join(', '),
      borderRadius:
          touch ? BorderRadius.zero : BorderRadius.circular(hollow.radiusMd),
      padding: touch
          ? const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm)
          : const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm, vertical: HollowSpacing.xxs),
      child: Row(
        children: [
          // Offline dims the picture; the name drops a text tier instead,
          // because faded text fails contrast.
          AnimatedOpacity(
            opacity: online ? 1 : 0.5,
            duration: HollowDurations.fast,
            child: PresenceAvatar(
              peerId: peerId,
              size: touch ? 40 : 32,
              online: online,
              ring: touch ? hollow.overlay : hollow.surface,
            ),
          ),
          SizedBox(width: touch ? HollowSpacing.md : HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.copyWith(
                          color: online
                              ? hollow.textPrimary
                              : hollow.textTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    ...nameTrailing,
                  ],
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (touch
                            ? HollowTypography.body
                            : HollowTypography.bodySmall)
                        .copyWith(color: hollow.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
