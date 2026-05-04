import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Overlay that shows notification cards in the bottom-right corner.
///
/// Up to 3 cards stacked vertically. Each card shows a header
/// (avatar + source name) and up to 5 accumulated messages.
/// Cards auto-dismiss after 5 seconds, hover pauses the timer.
/// Click navigates to the source conversation.
class NotificationOverlay extends ConsumerWidget {
  const NotificationOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(systemNotificationProvider);

    if (cards.isEmpty) return const SizedBox.shrink();

    // Stack cards from bottom, each card ~100px tall + 4px gap.
    // Newest at bottom, oldest at top.
    const cardHeight = 100.0;
    const gap = HollowSpacing.xxs;

    return Stack(
      children: [
        for (int i = 0; i < cards.length; i++)
          AnimatedPositioned(
            key: ValueKey(cards[i].sourceKey),
            duration: HollowDurations.normal,
            curve: Curves.easeOutCubic,
            right: HollowSpacing.lg,
            bottom: HollowSpacing.lg +
                (cards.length - 1 - i) * (cardHeight + gap),
            child: _NotificationCardWidget(
              key: ValueKey('card-${cards[i].sourceKey}'),
              card: cards[i],
            ),
          ),
      ],
    );
  }
}

/// A single notification card with auto-dismiss.
class _NotificationCardWidget extends ConsumerStatefulWidget {
  final NotificationCard card;

  const _NotificationCardWidget({
    super.key,
    required this.card,
  });

  @override
  ConsumerState<_NotificationCardWidget> createState() =>
      _NotificationCardWidgetState();
}

class _NotificationCardWidgetState
    extends ConsumerState<_NotificationCardWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  Timer? _dismissTimer;
  bool _hovering = false;

  static const _autoDismissDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 250),
      reverseDuration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 200),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _slide = Tween<Offset>(
      begin: const Offset(1.0, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    _controller.forward();
    _startDismissTimer();
  }

  @override
  void didUpdateWidget(_NotificationCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset timer when new messages arrive in this card.
    if (widget.card.messages.length != oldWidget.card.messages.length) {
      _restartDismissTimer();
    }
  }

  void _startDismissTimer() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_autoDismissDuration, _dismiss);
  }

  void _restartDismissTimer() {
    if (!_hovering) _startDismissTimer();
  }

  void _dismiss() {
    if (!mounted) return;
    _controller.reverse().then((_) {
      if (mounted) {
        ref
            .read(systemNotificationProvider.notifier)
            .dismissCard(widget.card.sourceKey);
      }
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTap() async {
    final card = widget.card;

    if (card.isDm && card.peerId != null) {
      ref.read(archiveTabOpenProvider.notifier).state = false;
      ref.read(shareTabOpenProvider.notifier).state = false;
      ref.read(selectedPeerProvider.notifier).state = card.peerId;
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(channelListProvider.notifier).clear();
      ref.read(selectedChannelProvider.notifier).state = null;
      ref.read(serverSettingsOpenProvider.notifier).state = false;
      ref.read(unreadProvider.notifier).markDmSeen(card.peerId!, null);
    } else if (card.serverId != null && card.channelId != null) {
      final channels =
          await ChannelListNotifier.fetchChannels(card.serverId!);
      final layout =
          await ChannelLayoutNotifier.fetchLayout(card.serverId!);

      if (!mounted) return;

      ref.read(archiveTabOpenProvider.notifier).state = false;
      ref.read(shareTabOpenProvider.notifier).state = false;
      ref.read(selectedPeerProvider.notifier).state = null;
      ref.read(serverSettingsOpenProvider.notifier).state = false;
      ref.read(channelListProvider.notifier).setChannels(channels);
      ref.read(channelLayoutProvider.notifier).setLayout(layout);
      ref.read(selectedChannelProvider.notifier).state = card.channelId;
      ref.read(selectedServerProvider.notifier).state = card.serverId;

      final map = Map<String, String>.from(
          ref.read(lastChannelPerServerProvider));
      map[card.serverId!] = card.channelId!;
      ref.read(lastChannelPerServerProvider.notifier).state = map;
    }

    ref
        .read(systemNotificationProvider.notifier)
        .dismissCard(card.sourceKey);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final card = widget.card;

    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _opacity,
        child: MouseRegion(
          onEnter: (_) {
            _hovering = true;
            _dismissTimer?.cancel();
          },
          onExit: (_) {
            _hovering = false;
            _startDismissTimer();
          },
          child: GestureDetector(
            onTap: _onTap,
            child: Container(
              width: 320,
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.2),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      HollowSpacing.md,
                      HollowSpacing.sm + 2,
                      HollowSpacing.sm,
                      HollowSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        HollowAvatar(
                          peerId: card.avatarId,
                          size: 24,
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        Expanded(
                          child: Text(
                            card.title,
                            style: HollowTypography.body.copyWith(
                              color: hollow.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Close button
                        HollowPressable(
                          onTap: _dismiss,
                          borderRadius:
                              BorderRadius.circular(hollow.radiusSm),
                          padding:
                              const EdgeInsets.all(HollowSpacing.xxs),
                          child: Icon(
                            LucideIcons.x,
                            size: 14,
                            color: hollow.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Divider
                  Container(
                    height: 1,
                    color: hollow.border.withValues(alpha: 0.5),
                  ),

                  // Messages
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.md,
                        vertical: HollowSpacing.sm,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = 0;
                              i < card.messages.length;
                              i++) ...[
                            if (i > 0)
                              const SizedBox(height: HollowSpacing.xxs),
                            _MessageRow(
                              message: card.messages[i],
                              isDm: card.isDm,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Single message row in a notification card.
class _MessageRow extends StatelessWidget {
  final NotificationMessage message;
  final bool isDm;

  const _MessageRow({
    required this.message,
    required this.isDm,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // For DMs, don't repeat the sender name (it's in the header).
    // For channels, show sender name since multiple people can send.
    if (isDm) {
      return Text(
        message.text,
        style: HollowTypography.body.copyWith(
          color: hollow.textSecondary,
          fontSize: 12,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${message.senderName}: ',
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
        Expanded(
          child: Text(
            message.text,
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
