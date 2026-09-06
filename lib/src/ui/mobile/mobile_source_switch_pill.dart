import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Source switcher pill for mobile call surfaces: one tab per active video
/// source, tapped to focus that source full-bleed.
///
/// Local SCREEN shares are never offered here, because the phone cannot preview
/// its own share without an infinite mirror; callers exclude it from [sources].
class MobileSourceSwitchPill extends ConsumerWidget {
  /// Active sources in display order: screens first, then cameras.
  final List<({String peerId, String type})> sources;
  final String? focusedPeerId;
  final String? focusedType;
  final String localPeerId;
  final void Function(String peerId, String type) onSelect;

  /// Screen sources not opted into yet (issue #38); the caller's [onSelect]
  /// starts watching them.
  final Set<String> unwatchedPeerIds;

  const MobileSourceSwitchPill({
    super.key,
    required this.sources,
    required this.focusedPeerId,
    required this.focusedType,
    required this.localPeerId,
    required this.onSelect,
    this.unwatchedPeerIds = const {},
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(HollowRadius.pill),
        border: Border.all(color: hollow.border.withValues(alpha: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: sources.map((source) {
            final isScreen = source.type == 'screen';
            final isFocused = source.peerId == focusedPeerId &&
                source.type == focusedType;
            final isUnwatched =
                isScreen && unwatchedPeerIds.contains(source.peerId);
            // Names and avatars are master-keyed; focus tracking stays on the
            // routable device id.
            final displayId =
                ref.watch(deviceLinkProvider).identityOf(source.peerId);
            final name = displayNameFor(profiles, displayId);

            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
              child: HollowPressable(
                onTap: () => onSelect(source.peerId, source.type),
                semanticLabel: isUnwatched
                    ? 'Watch screen share from ${source.peerId == localPeerId ? 'you' : name}'
                    : '${isScreen ? 'Screen' : 'Camera'}: ${source.peerId == localPeerId ? 'You' : name}',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                backgroundColor: isFocused ? hollow.accentMuted : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: HollowSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isUnwatched
                          ? LucideIcons.eye
                          : isScreen
                              ? LucideIcons.monitor
                              : LucideIcons.video,
                      size: 12,
                      color:
                          isFocused ? hollow.accent : hollow.textSecondary,
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    HollowAvatar(peerId: displayId, size: 18),
                    const SizedBox(width: HollowSpacing.xs),
                    Text(
                      source.peerId == localPeerId ? 'You' : name,
                      style: HollowTypography.caption.copyWith(
                        color: isFocused
                            ? hollow.textPrimary
                            : hollow.textSecondary,
                        fontWeight:
                            isFocused ? FontWeight.w600 : FontWeight.w400,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
