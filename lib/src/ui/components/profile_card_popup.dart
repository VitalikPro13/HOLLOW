import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/dialogs/user_settings_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Deterministic banner color from peer ID (shifted hue from avatar).
Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

/// Shows a profile card popup anchored near the tap position.
void showProfileCardPopup({
  required BuildContext context,
  required WidgetRef ref,
  required String peerId,
  String? nickname,
  String? role,
  required Offset anchor,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => _ProfileCardOverlay(
      peerId: peerId,
      nickname: nickname,
      role: role,
      anchor: anchor,
      onDismiss: () => entry.remove(),
    ),
  );

  overlay.insert(entry);
}

class _ProfileCardOverlay extends ConsumerStatefulWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final Offset anchor;
  final VoidCallback onDismiss;

  const _ProfileCardOverlay({
    required this.peerId,
    required this.nickname,
    required this.role,
    required this.anchor,
    required this.onDismiss,
  });

  @override
  ConsumerState<_ProfileCardOverlay> createState() =>
      _ProfileCardOverlayState();
}

class _ProfileCardOverlayState extends ConsumerState<_ProfileCardOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final profile = profiles[widget.peerId];
    final localPeerId = ref.watch(identityProvider).peerId;
    final isMe = widget.peerId == localPeerId;

    final displayName = profile?.displayName ?? '';
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final bannerColor = _bannerColorFromId(widget.peerId);

    final shownName = displayName.isNotEmpty
        ? displayName
        : (widget.peerId.length > 8
            ? '${widget.peerId.substring(0, 8)}...'
            : widget.peerId);

    const cardWidth = 280.0;

    // Position: card appears above and to the left of anchor
    final screenSize = MediaQuery.of(context).size;
    double left = widget.anchor.dx;
    double top = widget.anchor.dy;

    // Clamp
    if (left < 8) left = 8;
    if (left + cardWidth > screenSize.width - 8) {
      left = screenSize.width - cardWidth - 8;
    }
    if (top < 8) top = 8;

    return Stack(
      children: [
        // Dismiss barrier
        Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),

        // Card with animation
        Positioned(
          left: left,
          top: top,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: cardWidth,
                  decoration: BoxDecoration(
                    color: haven.surface.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(haven.radiusLg),
                    border: Border.all(
                      color: haven.accent.withValues(alpha: 0.15),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 28,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Banner
                      Container(
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              bannerColor,
                              bannerColor.withValues(alpha: 0.7),
                            ],
                          ),
                        ),
                      ),

                      // Content overlapping banner
                      Transform.translate(
                        offset: const Offset(0, -32),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: HavenSpacing.md,
                          ),
                          child: Column(
                            children: [
                              // Avatar
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                      haven.radiusMd + 2),
                                  border: Border.all(
                                    color: haven.surface,
                                    width: 3,
                                  ),
                                ),
                                child: HavenAvatar(
                                    peerId: widget.peerId, size: 64),
                              ),

                              const SizedBox(height: HavenSpacing.xs + 2),

                              // Name(s) — centered
                              if (widget.nickname != null &&
                                  widget.nickname!.isNotEmpty) ...[
                                Text(
                                  widget.nickname!,
                                  style:
                                      HavenTypography.subheading.copyWith(
                                    color: haven.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                                Text(
                                  shownName,
                                  style: HavenTypography.caption.copyWith(
                                    color: haven.textSecondary,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ] else ...[
                                Text(
                                  shownName,
                                  style:
                                      HavenTypography.subheading.copyWith(
                                    color: haven.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],

                              // Role badge
                              if (widget.role != null &&
                                  widget.role!.isNotEmpty &&
                                  widget.role != 'member') ...[
                                const SizedBox(height: HavenSpacing.xs),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: HavenSpacing.sm,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _roleColor(widget.role!, haven)
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(
                                        HavenRadius.sm),
                                  ),
                                  child: Text(
                                    widget.role![0].toUpperCase() +
                                        widget.role!.substring(1),
                                    style:
                                        HavenTypography.caption.copyWith(
                                      color:
                                          _roleColor(widget.role!, haven),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ],

                              // Status (before divider)
                              if (status.isNotEmpty) ...[
                                const SizedBox(height: HavenSpacing.xs),
                                Text(
                                  status,
                                  style: HavenTypography.caption.copyWith(
                                    color: haven.textSecondary,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],

                              const SizedBox(height: HavenSpacing.sm),

                              // Divider
                              Container(height: 1, color: haven.border),

                              // About Me
                              if (aboutMe.isNotEmpty) ...[
                                const SizedBox(height: HavenSpacing.sm),
                                Text(
                                  'ABOUT ME',
                                  style: HavenTypography.caption.copyWith(
                                    color: haven.textSecondary,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    fontSize: 9,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: HavenSpacing.xxs),
                                Text(
                                  aboutMe,
                                  style: HavenTypography.caption.copyWith(
                                    color: haven.textSecondary,
                                    fontSize: 11,
                                  ),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],

                              // Edit Profile button (self only)
                              if (isMe) ...[
                                const SizedBox(height: HavenSpacing.sm),
                                SizedBox(
                                  width: double.infinity,
                                  child: HavenButton.outline(
                                    onPressed: () {
                                      // Capture navigator context before dismiss destroys overlay
                                      final navContext =
                                          Navigator.of(context).context;
                                      widget.onDismiss();
                                      showUserSettingsDialog(navContext, ref);
                                    },
                                    compact: true,
                                    icon: const Icon(LucideIcons.pencil),
                                    child: const Text('Edit Profile'),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // Peer ID footer — minimal, tucked into bottom
                      Transform.translate(
                        offset: const Offset(0, -28),
                        child: GestureDetector(
                          onTap: () {
                            Clipboard.setData(
                              ClipboardData(text: widget.peerId),
                            );
                            HavenToast.show(
                              context,
                              'Peer ID copied',
                              type: HavenToastType.success,
                              duration: const Duration(seconds: 1),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  LucideIcons.copy,
                                  size: 8,
                                  color: haven.textSecondary
                                      .withValues(alpha: 0.35),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.peerId.length > 16
                                      ? widget.peerId.substring(
                                          widget.peerId.length - 8)
                                      : widget.peerId,
                                  style: HavenTypography.mono.copyWith(
                                    color: haven.textSecondary
                                        .withValues(alpha: 0.35),
                                    fontSize: 8,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Role badge color.
Color _roleColor(String role, HavenTheme haven) {
  return switch (role) {
    'owner' => haven.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(haven.warning, haven.error, 0.5) ?? haven.warning,
    _ => haven.textSecondary,
  };
}
