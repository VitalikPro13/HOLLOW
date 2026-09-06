import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/link_health_chip.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileClusteredAvatars extends StatelessWidget {
  final List<String> participants;
  final Set<String> speakingSet;
  final Set<String> mutedSet;
  final Set<String> deafenedSet;

  const MobileClusteredAvatars({
    super.key,
    required this.participants,
    required this.speakingSet,
    this.mutedSet = const {},
    this.deafenedSet = const {},
  });

  @override
  Widget build(BuildContext context) {
    final count = participants.length;
    final avatarSize = count <= 2 ? 96.0 : count <= 4 ? 80.0 : 64.0;
    final gap = avatarSize * 0.25;

    final List<List<String>> rows;
    switch (count) {
      case 1:
        rows = [
          [participants[0]]
        ];
      case 2:
        rows = [participants];
      case 3:
        rows = [
          participants.sublist(0, 2),
          [participants[2]],
        ];
      case 4:
        rows = [
          participants.sublist(0, 2),
          participants.sublist(2, 4),
        ];
      case 5:
        rows = [
          participants.sublist(0, 2),
          [participants[2]],
          participants.sublist(3, 5),
        ];
      default:
        rows = [];
        for (var i = 0; i < count; i += 3) {
          rows.add(participants.sublist(i, (i + 3).clamp(0, count)));
        }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int r = 0; r < rows.length; r++) ...[
          if (r > 0) SizedBox(height: gap),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int c = 0; c < rows[r].length; c++) ...[
                if (c > 0) SizedBox(width: gap),
                MobileSpeakingAvatar(
                  peerId: rows[r][c],
                  size: avatarSize,
                  isSpeaking: speakingSet.contains(rows[r][c]),
                  isMuted: mutedSet.contains(rows[r][c]),
                  isDeafened: deafenedSet.contains(rows[r][c]),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class MobileSpeakingAvatar extends ConsumerWidget {
  final String peerId;
  final double size;
  final bool isSpeaking;
  final bool isMuted;
  final bool isDeafened;

  const MobileSpeakingAvatar({
    super.key,
    required this.peerId,
    required this.size,
    required this.isSpeaking,
    this.isMuted = false,
    this.isDeafened = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    // VC participants are keyed by the ROUTABLE WS sender, a DEVICE id for
    // multi-device peers, while avatar and name lookups are master-keyed.
    final displayId = ref.watch(deviceLinkProvider).identityOf(peerId);
    final displayName = displayNameFor(profiles, displayId);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final myDevice = ref.watch(localDevicePeerIdProvider).valueOrNull;
    final isMe = peerId == localPeerId || peerId == myDevice;
    final radius = hollow.radiusMd;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SpeakingBorder(
          isSpeaking: isSpeaking,
          borderWidth: 3.0,
          glowBlur: 16,
          glowSpread: 2.0,
          padding: 4.0,
          borderRadius: BorderRadius.circular(radius + 4),
          child: Stack(
            children: [
              // No frame under a speaking ring: the two are the same picture.
              HollowAvatar(peerId: displayId, size: size, frameId: ''),
              // Muted badge bottom-left, deafened badge bottom-right.
              if (isMuted)
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: _AvatarBadge(
                    icon: LucideIcons.micOff,
                    hollow: hollow,
                    radius: radius,
                  ),
                ),
              if (isDeafened)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _AvatarBadge(
                    icon: LucideIcons.headphoneOff,
                    hollow: hollow,
                    radius: radius,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          isMe ? 'You' : displayName,
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        // In a mesh, a member on bad Wi-Fi is that member's leg, so the flair
        // belongs on their avatar and never on the channel. Our own avatar has
        // no leg of its own to report.
        if (!isMe)
          Consumer(builder: (context, ref, _) {
            final health =
                ref.watch(vcLinkHealthProvider.select((m) => m[peerId]));
            if (health == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.xxs),
              child: LinkHealthChip(snapshot: health, compact: true),
            );
          }),
      ],
    );
  }
}

/// Small status badge pinned to an avatar corner (muted / deafened).
class _AvatarBadge extends StatelessWidget {
  final IconData icon;
  final HollowTheme hollow;
  final double radius;

  const _AvatarBadge({
    required this.icon,
    required this.hollow,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: hollow.error,
        borderRadius: BorderRadius.circular(radius * 0.6),
        border: Border.all(color: hollow.background, width: 2),
      ),
      child: Icon(icon, size: 12, color: Colors.white),
    );
  }
}

class MobileControlButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final double size;
  final Color color;
  final Color backgroundColor;
  final VoidCallback? onTap;

  /// Optional secondary action, such as the speaker button's route picker.
  final VoidCallback? onLongPress;

  /// Screen-reader name for this icon-only control.
  final String? semanticLabel;

  const MobileControlButton({
    super.key,
    required this.icon,
    required this.iconSize,
    required this.size,
    required this.color,
    required this.backgroundColor,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedOpacity(
          opacity: onTap != null ? 1.0 : 0.4,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: backgroundColor,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(icon, size: iconSize, color: color),
            ),
          ),
        ),
      ),
    );
  }
}
