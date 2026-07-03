import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

Color bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

void showMobileProfileSheet(
  BuildContext context, {
  required String peerId,
  String? role,
  String? twitchUsername,
  List<crdt_api.LabelFfi>? labels,
}) {
  final hollow = HollowTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: hollow.surface,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (_) => MobileProfileSheet(
      peerId: peerId,
      role: role,
      twitchUsername: twitchUsername,
      labels: labels,
    ),
  );
}

Color _roleColor(String role, HollowTheme hollow) {
  switch (role) {
    case 'owner':
      return hollow.warning;
    case 'admin':
      return const Color(0xFFA78BFA);
    case 'moderator':
      return Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning;
    default:
      return hollow.textSecondary;
  }
}

class MobileProfileSheet extends ConsumerWidget {
  final String peerId;
  final String? role;
  final String? twitchUsername;
  final List<crdt_api.LabelFfi>? labels;

  const MobileProfileSheet({
    super.key,
    required this.peerId,
    this.role,
    this.twitchUsername,
    this.labels,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final profile = profiles[peerId];
    final localNicknames = ref.watch(localNicknameProvider);
    final localNick = localNicknames[peerId];
    final name = localNick ?? displayNameFor(profiles, peerId);
    // The friend's OWN name (their profile display name), NOT folded through the
    // local nickname — so the subtitle under a local nickname shows the real
    // name, not a duplicate. Falls back to short peer ID when unset.
    final profileName = (profile != null && profile.displayName.isNotEmpty)
        ? profile.displayName
        : (peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId);
    final isOnline = identityIsOnline(ref, peerId);
    final bannerBytes = ref.watch(bannerProvider(peerId)).valueOrNull;
    final bannerColor = bannerColorFromId(peerId);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';
    final isMe = peerId == myPeerId;
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];
    final effectiveTwitch = (twitchUsername != null && twitchUsername!.isNotEmpty)
        ? twitchUsername!
        : (profile?.twitchUsername ?? '');

    return SafeArea(
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle
        Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.sm),
          child: Container(
            width: 32, height: 4,
            decoration: BoxDecoration(
              color: hollow.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Banner
        const SizedBox(height: HollowSpacing.sm),
        SizedBox(
          height: 180,
          width: double.infinity,
          child: bannerBytes != null && bannerBytes.isNotEmpty
              ? AnimatedGifImage(
                  bytes: bannerBytes,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorWidget: Container(
                    height: 180,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                      ),
                    ),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                    ),
                  ),
                ),
        ),

        // Avatar + info overlapping banner
        Transform.translate(
          offset: const Offset(0, -36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.surface, width: 3),
                ),
                child: HollowAvatar(peerId: peerId, size: 72, semanticLabel: name),
              ),
              const SizedBox(height: HollowSpacing.sm),

              // Name (with local nickname)
              if (localNick != null) ...[
                Text(localNick, style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                )),
                Text(profileName, style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                )),
              ] else
                Text(name, style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                )),

              const SizedBox(height: HollowSpacing.xs),

              // Online status
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  StatusDot(
                    color: isOnline ? hollow.success : hollow.textSecondary,
                    size: 8, pulse: isOnline,
                    filled: isOnline,
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  Text(
                    isOnline ? 'Online' : 'Offline',
                    style: HollowTypography.body.copyWith(
                      color: isOnline ? hollow.success : hollow.textSecondary,
                    ),
                  ),
                ],
              ),

              // Role badge
              if (role != null && role != 'member') ...[
                const SizedBox(height: HollowSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: _roleColor(role!, hollow).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                  ),
                  child: Text(
                    role![0].toUpperCase() + role!.substring(1),
                    style: HollowTypography.bodySmall.copyWith(
                      color: _roleColor(role!, hollow),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],

              // Labels
              if (labels != null && labels!.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Wrap(
                    spacing: HollowSpacing.xs,
                    runSpacing: HollowSpacing.xs,
                    alignment: WrapAlignment.center,
                    children: labels!.map((label) {
                      final color = _parseLabelColor(label.color);
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: HollowSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          border: Border.all(color: color.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          label.name,
                          style: HollowTypography.caption.copyWith(
                            color: color,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],

              // Twitch badge
              if (effectiveTwitch.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                HollowPressable(
                  onTap: () => launchUrl(
                    Uri.parse('https://twitch.tv/$effectiveTwitch'),
                    mode: LaunchMode.externalApplication,
                  ),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(BrandIcons.twitch, size: 14, color: const Color(0xFF9146FF)),
                      const SizedBox(width: HollowSpacing.xs),
                      Text(
                        effectiveTwitch,
                        style: HollowTypography.bodySmall.copyWith(
                          color: const Color(0xFF9146FF),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Status
              if (profile?.status != null && profile!.status.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                Text(
                  profile.status,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.accent,
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],

              // About me
              if (profile?.aboutMe != null && profile!.aboutMe.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Text(
                    profile.aboutMe,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],

              const SizedBox(height: HollowSpacing.lg),

              // Action buttons
              if (!isMe) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Column(
                    children: [
                      // Message button
                      if (friendInfo?.status == 'accepted')
                        Padding(
                          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                          child: HollowButton.filled(
                            onPressed: () {
                              final nav =
                                  Navigator.of(context, rootNavigator: true);
                              final container = ProviderScope.containerOf(
                                  context,
                                  listen: false);
                              Navigator.of(context).pop();
                              ref.read(selectedPeerProvider.notifier).state = peerId;
                              nav.push(
                                hollowMobileRoute(
                                  settings: const RouteSettings(
                                      name: MobileChatRoute.routeName),
                                  builder: (_) => MobileChatRoute(peerId: peerId),
                                ),
                              ).then((_) {
                                // Guarded: only clear if this chat is still the
                                // selected one (the sheet is gone by now — use
                                // the captured container, not ref).
                                if (container.read(selectedPeerProvider) ==
                                    peerId) {
                                  container
                                      .read(selectedPeerProvider.notifier)
                                      .state = null;
                                }
                              });
                            },
                            icon: const Icon(LucideIcons.messageCircle, size: 16),
                            expand: true,
                            child: const Text('Message'),
                          ),
                        ),

                      // Set nickname button
                      Padding(
                        padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                        child: HollowButton.outline(
                          onPressed: () => _showNicknameDialog(context, ref),
                          icon: Icon(
                            localNick != null ? LucideIcons.pencil : LucideIcons.tag,
                            size: 16,
                          ),
                          expand: true,
                          child: Text(localNick != null ? 'Edit Nickname' : 'Set Nickname'),
                        ),
                      ),

                      // Friend action
                      _FriendActionRow(peerId: peerId),
                    ],
                  ),
                ),
              ],

              // Peer ID
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                child: HollowPressable(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: peerId));
                    HollowToast.show(context, 'Peer ID copied',
                        type: HollowToastType.success);
                  },
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${peerId.substring(0, 8)}...${peerId.substring(peerId.length - 8)}',
                        style: HollowTypography.mono.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      Icon(LucideIcons.copy, size: 12, color: hollow.textSecondary),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: HollowSpacing.md),
            ],
          ),
        ),
      ],
    ),
    );
  }

  void _showNicknameDialog(BuildContext context, WidgetRef ref) {
    final current = ref.read(localNicknameProvider)[peerId] ?? '';
    final controller = TextEditingController(text: current);
    showHollowDialog(
      context: context,
      builder: (_) => _NicknameDialog(
        peerId: peerId,
        controller: controller,
      ),
    );
  }
}

Color _parseLabelColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length == 6) {
    return Color(int.parse('FF$cleaned', radix: 16));
  }
  if (cleaned.length == 8) {
    return Color(int.parse(cleaned, radix: 16));
  }
  return const Color(0xFF78909C);
}

class _FriendActionRow extends ConsumerWidget {
  final String peerId;

  const _FriendActionRow({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];

    if (friendInfo == null) {
      return HollowButton.ghost(
        onPressed: () async {
          try {
            await ref.read(friendsProvider.notifier).sendRequest(peerId);
            if (context.mounted) {
              HollowToast.show(context, 'Friend request sent',
                  type: HollowToastType.success);
            }
          } catch (e) {
            if (context.mounted) {
              HollowToast.show(context, 'Failed to send request',
                  type: HollowToastType.error);
            }
          }
        },
        icon: const Icon(LucideIcons.userPlus, size: 16),
        expand: true,
        child: const Text('Add Friend'),
      );
    }

    if (friendInfo.status == 'pending' && friendInfo.direction == 'incoming') {
      return HollowButton.filled(
        onPressed: () {
          ref.read(friendsProvider.notifier).acceptRequest(peerId);
          HollowToast.show(context, 'Friend request accepted',
              type: HollowToastType.success);
        },
        icon: const Icon(LucideIcons.check, size: 16),
        expand: true,
        child: const Text('Accept Request'),
      );
    }

    if (friendInfo.status == 'pending') {
      return HollowButton.ghost(
        onPressed: null,
        icon: const Icon(LucideIcons.clock, size: 16),
        expand: true,
        child: const Text('Request Sent'),
      );
    }

    // Accepted — show friends indicator
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.checkCheck, size: 14, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text('Friends', style: HollowTypography.bodySmall.copyWith(
            color: hollow.success,
          )),
        ],
      ),
    );
  }
}

class _NicknameDialog extends ConsumerStatefulWidget {
  final String peerId;
  final TextEditingController controller;

  const _NicknameDialog({required this.peerId, required this.controller});

  @override
  ConsumerState<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends ConsumerState<_NicknameDialog> {
  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Set Nickname',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Only visible to you.',
              style: HollowTypography.bodySmall),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: widget.controller,
            hintText: 'Nickname',
            maxLength: 32,
            showCounter: true,
            autofocus: true,
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final nickname = widget.controller.text.trim();
    await ref.read(localNicknameProvider.notifier).setNickname(widget.peerId, nickname);
    if (mounted) {
      Navigator.of(context).pop();
      HollowToast.show(
        context,
        nickname.isEmpty ? 'Nickname cleared' : 'Nickname set',
        type: HollowToastType.success,
      );
    }
  }
}
