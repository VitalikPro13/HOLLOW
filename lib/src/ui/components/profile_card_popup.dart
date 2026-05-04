import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:hollow/src/rust/api/twitch.dart';

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
  String? twitchUsername,
  List<crdt_api.LabelFfi>? labels,
  required Offset anchor,
  bool anchorBottom = false,
}) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => _ProfileCardOverlay(
      peerId: peerId,
      nickname: nickname,
      role: role,
      twitchUsername: twitchUsername,
      labels: labels,
      anchor: anchor,
      anchorBottom: anchorBottom,
      onDismiss: () { entry.remove(); entry.dispose(); },
    ),
  );

  overlay.insert(entry);
}

class _ProfileCardOverlay extends ConsumerStatefulWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final String? twitchUsername;
  final List<crdt_api.LabelFfi>? labels;
  final Offset anchor;
  final bool anchorBottom;
  final VoidCallback onDismiss;

  const _ProfileCardOverlay({
    required this.peerId,
    required this.nickname,
    required this.role,
    this.twitchUsername,
    this.labels,
    required this.anchor,
    this.anchorBottom = false,
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
  String? _resolvedTwitchUsername;

  @override
  void initState() {
    super.initState();
    _resolvedTwitchUsername = widget.twitchUsername;
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 180),
    );
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();

    if (_resolvedTwitchUsername == null || _resolvedTwitchUsername!.isEmpty) {
      _resolveTwitchUsername();
    }
  }

  Future<void> _resolveTwitchUsername() async {
    try {
      final localPeerId = ref.read(identityProvider).peerId;
      if (widget.peerId == localPeerId) {
        final username = await twitchGetUsername();
        if (mounted && username != null && username.isNotEmpty) {
          setState(() => _resolvedTwitchUsername = username);
          return;
        }
      }
      // Fallback: check profile DB for any peer's Twitch username
      final profiles = ref.read(profileProvider);
      final profile = profiles[widget.peerId];
      if (mounted && profile != null && profile.twitchUsername.isNotEmpty) {
        setState(() => _resolvedTwitchUsername = profile.twitchUsername);
      }
    } catch (_) {}
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
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final profile = profiles[widget.peerId];
    final localPeerId = ref.watch(identityProvider).peerId;
    final isMe = widget.peerId == localPeerId;

    final displayName = profile?.displayName ?? '';
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final bannerColor = _bannerColorFromId(widget.peerId);
    final localNicknames = ref.watch(localNicknameProvider);
    final localNick = localNicknames[widget.peerId];

    final shownName = displayName.isNotEmpty
        ? displayName
        : (widget.peerId.length > 8
            ? '${widget.peerId.substring(0, 8)}...'
            : widget.peerId);

    const cardWidth = 280.0;

    // Position: card appears near the anchor
    final screenSize = MediaQuery.of(context).size;
    double left = widget.anchor.dx;

    // Clamp horizontal
    if (left < 8) left = 8;
    if (left + cardWidth > screenSize.width - 8) {
      left = screenSize.width - cardWidth - 8;
    }

    // Vertical positioning
    double? top;
    double? bottom;
    if (widget.anchorBottom) {
      // anchor.dy is where the card's bottom should be
      bottom = screenSize.height - widget.anchor.dy;
      if (bottom < 8) bottom = 8;
    } else {
      top = widget.anchor.dy;
      if (top < 8) top = 8;
    }

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
          bottom: bottom,
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
                    color: hollow.surface.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(hollow.radiusLg),
                    border: Border.all(
                      color: hollow.accent.withValues(alpha: 0.15),
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
                      Builder(builder: (_) {
                        final bannerBytes = ref.watch(bannerProvider(widget.peerId)).valueOrNull;
                        if (bannerBytes != null && bannerBytes.isNotEmpty) {
                          return SizedBox(
                            height: 80,
                            width: double.infinity,
                            child: AnimatedGifImage(bytes: bannerBytes, height: 80, width: double.infinity, fit: BoxFit.cover,
                              errorWidget: Container(
                                height: 80,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                        return Container(
                          height: 80,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                            ),
                          ),
                        );
                      }),

                      // Content overlapping banner
                      Transform.translate(
                        offset: const Offset(0, -32),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: HollowSpacing.md,
                          ),
                          child: Column(
                            children: [
                              // Avatar
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                      hollow.radiusMd + 2),
                                  border: Border.all(
                                    color: hollow.surface,
                                    width: 3,
                                  ),
                                ),
                                child: HollowAvatar(
                                    peerId: widget.peerId, size: 64, animate: true),
                              ),

                              const SizedBox(height: HollowSpacing.xs + 2),

                              // Name(s) — centered
                              // Priority: local nickname → server nickname → profile name
                              Builder(builder: (_) {
                                final primaryName = localNick ?? widget.nickname;
                                final hasSecondary = primaryName != null && primaryName.isNotEmpty;
                                if (hasSecondary) {
                                  return Column(
                                    children: [
                                      Text(
                                        primaryName,
                                        style: HollowTypography.subheading.copyWith(
                                          color: hollow.textPrimary,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                      Text(
                                        shownName,
                                        style: HollowTypography.caption.copyWith(
                                          color: hollow.textSecondary,
                                          fontSize: 11,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  );
                                }
                                return Text(
                                  shownName,
                                  style: HollowTypography.subheading.copyWith(
                                    color: hollow.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                );
                              }),

                              // Role badge
                              if (widget.role != null &&
                                  widget.role!.isNotEmpty &&
                                  widget.role != 'member') ...[
                                const SizedBox(height: HollowSpacing.xs),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: HollowSpacing.sm,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _roleColor(widget.role!, hollow)
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(
                                        HollowRadius.sm),
                                  ),
                                  child: Text(
                                    widget.role![0].toUpperCase() +
                                        widget.role!.substring(1),
                                    style:
                                        HollowTypography.caption.copyWith(
                                      color:
                                          _roleColor(widget.role!, hollow),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ],

                              // Labels
                              if (widget.labels != null &&
                                  widget.labels!.isNotEmpty) ...[
                                const SizedBox(height: HollowSpacing.xs),
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  alignment: WrapAlignment.center,
                                  children: widget.labels!.map((l) {
                                    final c = _parseLabelColor(l.color);
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: c.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(
                                            HollowRadius.sm),
                                      ),
                                      child: Text(
                                        l.name,
                                        style: HollowTypography.caption
                                            .copyWith(
                                          color: c,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 10,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],

                              // Twitch badge
                              if (_resolvedTwitchUsername != null &&
                                  _resolvedTwitchUsername!.isNotEmpty) ...[
                                const SizedBox(height: HollowSpacing.xs),
                                GestureDetector(
                                  onTap: () {
                                    launchUrl(
                                      Uri.parse(
                                          'https://twitch.tv/${_resolvedTwitchUsername}'),
                                      mode: LaunchMode.externalApplication,
                                    );
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: HollowSpacing.sm,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF9146FF)
                                          .withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(
                                          HollowRadius.sm),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(SimpleIcons.twitch,
                                            size: 11,
                                            color: const Color(0xFF9146FF)),
                                        const SizedBox(width: 4),
                                        Text(
                                          _resolvedTwitchUsername!,
                                          style: HollowTypography.caption
                                              .copyWith(
                                            color: const Color(0xFF9146FF),
                                            fontWeight: FontWeight.w600,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],

                              // Status (before divider)
                              if (status.isNotEmpty) ...[
                                const SizedBox(height: HollowSpacing.xs),
                                Text(
                                  status,
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],

                              const SizedBox(height: HollowSpacing.sm),

                              // Divider
                              Container(height: 1, color: hollow.border),

                              // About Me
                              if (aboutMe.isNotEmpty) ...[
                                const SizedBox(height: HollowSpacing.sm),
                                Text(
                                  'ABOUT ME',
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    fontSize: 9,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: HollowSpacing.xxs),
                                Text(
                                  aboutMe,
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                    fontSize: 11,
                                  ),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ],

                              // Edit Profile button (self only)
                              if (isMe) ...[
                                const SizedBox(height: HollowSpacing.sm),
                                SizedBox(
                                  width: double.infinity,
                                  child: HollowButton.outline(
                                    onPressed: () {
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

                              // Set Nickname + Friend action (non-self only)
                              if (!isMe) ...[
                                const SizedBox(height: HollowSpacing.sm),
                                SizedBox(
                                  width: double.infinity,
                                  child: Builder(builder: (_) {
                                    final localNicks = ref.watch(localNicknameProvider);
                                    final hasNick = localNicks.containsKey(widget.peerId);
                                    return HollowButton.ghost(
                                      onPressed: () {
                                        final peerId = widget.peerId;
                                        final nick = localNicks[peerId] ?? '';
                                        final navContext = Navigator.of(context, rootNavigator: true).context;
                                        widget.onDismiss();
                                        showLocalNicknameDialog(
                                          navContext, ref, peerId,
                                          currentNickname: nick,
                                        );
                                      },
                                      compact: true,
                                      icon: Icon(
                                        hasNick ? LucideIcons.pencil : LucideIcons.tag,
                                      ),
                                      child: Text(hasNick ? 'Edit Nickname' : 'Set Nickname'),
                                    );
                                  }),
                                ),
                                const SizedBox(height: HollowSpacing.xs),
                                _FriendActionButton(
                                  peerId: widget.peerId,
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
                            HollowToast.show(
                              context,
                              'Peer ID copied',
                              type: HollowToastType.success,
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
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.35),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.peerId.length > 16
                                      ? widget.peerId.substring(
                                          widget.peerId.length - 8)
                                      : widget.peerId,
                                  style: HollowTypography.mono.copyWith(
                                    color: hollow.textSecondary
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

/// Friend action button in profile card — shows state-aware button.
/// - Not a friend: "Add Friend" button
/// - Pending outgoing: "Request Sent" (disabled)
/// - Pending incoming: "Accept Request" button
/// - Accepted: checkmark icon "Friends"
class _FriendActionButton extends ConsumerWidget {
  final String peerId;

  const _FriendActionButton({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];

    if (friendInfo == null) {
      // Not a friend — show "Add Friend" button.
      return SizedBox(
        width: double.infinity,
        child: HollowButton.outline(
          onPressed: () =>
              ref.read(friendsProvider.notifier).sendRequest(peerId),
          compact: true,
          icon: const Icon(LucideIcons.userPlus),
          child: const Text('Add Friend'),
        ),
      );
    }

    if (friendInfo.status == 'pending') {
      if (friendInfo.direction == 'incoming') {
        // Incoming request — show "Accept" button.
        return SizedBox(
          width: double.infinity,
          child: HollowButton.filled(
            onPressed: () =>
                ref.read(friendsProvider.notifier).acceptRequest(peerId),
            compact: true,
            icon: const Icon(LucideIcons.check),
            child: const Text('Accept Request'),
          ),
        );
      }
      // Outgoing request — show "Pending" indicator.
      return SizedBox(
        width: double.infinity,
        child: HollowButton.ghost(
          onPressed: null,
          compact: true,
          icon: Icon(LucideIcons.clock, color: hollow.textSecondary),
          child: Text(
            'Request Sent',
            style: TextStyle(color: hollow.textSecondary),
          ),
        ),
      );
    }

    // Accepted friend — show "Friends" indicator.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(LucideIcons.userCheck, size: 14, color: hollow.success),
        const SizedBox(width: HollowSpacing.xs),
        Text(
          'Friends',
          style: HollowTypography.body.copyWith(
            color: hollow.success,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

Color _parseLabelColor(String hex) {
  final cleaned = hex.replaceAll('#', '');
  if (cleaned.length == 6) {
    return Color(int.parse('FF$cleaned', radix: 16));
  }
  return const Color(0xFF78909C);
}

/// Role badge color.
Color _roleColor(String role, HollowTheme hollow) {
  return switch (role) {
    'owner' => hollow.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning,
    _ => hollow.textSecondary,
  };
}

/// Show a dialog to set/edit/clear a local nickname for a peer.
void showLocalNicknameDialog(
  BuildContext context,
  WidgetRef ref,
  String peerId, {
  String currentNickname = '',
}) {
  showHollowDialog(
    context: context,
    builder: (ctx) => _LocalNicknameDialog(
      peerId: peerId,
      currentNickname: currentNickname,
    ),
  );
}

class _LocalNicknameDialog extends ConsumerStatefulWidget {
  final String peerId;
  final String currentNickname;

  const _LocalNicknameDialog({
    required this.peerId,
    required this.currentNickname,
  });

  @override
  ConsumerState<_LocalNicknameDialog> createState() =>
      _LocalNicknameDialogState();
}

class _LocalNicknameDialogState extends ConsumerState<_LocalNicknameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentNickname);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final nickname = _controller.text.trim();
    ref.read(localNicknameProvider.notifier).setNickname(
          widget.peerId,
          nickname,
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(HollowSpacing.xl),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set Nickname',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: HollowSpacing.xs),
              Text(
                'Only visible to you',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: HollowSpacing.md),
              HollowTextField(
                controller: _controller,
                hintText: 'Nickname (leave empty to clear)',
                maxLength: 32,
                autofocus: true,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HollowButton.ghost(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.filled(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
