import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ─────────────────────────────────────────────────
// Clustered avatar layout with speaking indicators
// ─────────────────────────────────────────────────

class MobileClusteredAvatars extends StatelessWidget {
  final List<String> participants;
  final Set<String> speakingSet;
  final Set<String> mutedSet;

  const MobileClusteredAvatars({
    super.key,
    required this.participants,
    required this.speakingSet,
    this.mutedSet = const {},
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
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Single avatar with animated teal speaking glow (rounded square)
// ─────────────────────────────────────────────────

class MobileSpeakingAvatar extends ConsumerStatefulWidget {
  final String peerId;
  final double size;
  final bool isSpeaking;
  final bool isMuted;

  const MobileSpeakingAvatar({
    super.key,
    required this.peerId,
    required this.size,
    required this.isSpeaking,
    this.isMuted = false,
  });

  @override
  ConsumerState<MobileSpeakingAvatar> createState() =>
      _MobileSpeakingAvatarState();
}

class _MobileSpeakingAvatarState extends ConsumerState<MobileSpeakingAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _glowController;
  late Animation<double> _glowAnim;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _glowAnim = CurvedAnimation(
      parent: _glowController,
      curve: Curves.easeOut,
    );
    if (widget.isSpeaking) _glowController.forward();
  }

  @override
  void didUpdateWidget(MobileSpeakingAvatar old) {
    super.didUpdateWidget(old);
    if (widget.isSpeaking && !old.isSpeaking) {
      _glowController.forward();
    } else if (!widget.isSpeaking && old.isSpeaking) {
      _glowController.reverse();
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final displayName = displayNameFor(profiles, widget.peerId);
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final isMe = widget.peerId == localPeerId;
    final radius = hollow.radiusMd;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _glowAnim,
          builder: (context, child) {
            return Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius + 4),
                border: Border.all(
                  color: hollow.accent
                      .withValues(alpha: _glowAnim.value * 0.9),
                  width: 3 * _glowAnim.value,
                ),
                boxShadow: _glowAnim.value > 0.01
                    ? [
                        BoxShadow(
                          color: hollow.accent
                              .withValues(alpha: _glowAnim.value * 0.3),
                          blurRadius: 16 * _glowAnim.value,
                          spreadRadius: 2 * _glowAnim.value,
                        ),
                      ]
                    : null,
              ),
              child: child,
            );
          },
          child: Stack(
            children: [
              HollowAvatar(peerId: widget.peerId, size: widget.size),
              if (widget.isMuted)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: hollow.error,
                      borderRadius: BorderRadius.circular(radius * 0.6),
                      border:
                          Border.all(color: hollow.background, width: 2),
                    ),
                    child: Icon(LucideIcons.micOff,
                        size: 12, color: Colors.white),
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
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Circular control button
// ─────────────────────────────────────────────────

class MobileControlButton extends StatelessWidget {
  final IconData icon;
  final double iconSize;
  final double size;
  final Color color;
  final Color backgroundColor;
  final VoidCallback? onTap;

  const MobileControlButton({
    super.key,
    required this.icon,
    required this.iconSize,
    required this.size,
    required this.color,
    required this.backgroundColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
    );
  }
}
