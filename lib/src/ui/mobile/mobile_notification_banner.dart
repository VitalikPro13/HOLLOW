import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';

class MobileNotificationBanner extends ConsumerStatefulWidget {
  const MobileNotificationBanner({super.key});

  @override
  ConsumerState<MobileNotificationBanner> createState() =>
      _MobileNotificationBannerState();
}

class _MobileNotificationBannerState
    extends ConsumerState<MobileNotificationBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _opacity;
  Timer? _dismissTimer;
  NotificationCard? _currentCard;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 300),
      reverseDuration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 200),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _show(NotificationCard card) {
    _currentCard = card;
    _lastMessageCount = card.messages.length;
    _controller.forward();
    _startDismissTimer();
  }

  void _startDismissTimer() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 4), _dismiss);
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    _controller.reverse().then((_) {
      if (mounted) {
        final key = _currentCard?.sourceKey;
        _currentCard = null;
        if (key != null) {
          ref.read(systemNotificationProvider.notifier).dismissCard(key);
        }
      }
    });
  }

  void _onTap() {
    final card = _currentCard;
    if (card == null) return;

    _dismissTimer?.cancel();
    ref.read(systemNotificationProvider.notifier).dismissCard(card.sourceKey);

    if (card.isDm && card.peerId != null) {
      ref.read(selectedPeerProvider.notifier).state = card.peerId;
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(unreadProvider.notifier).markDmSeen(card.peerId!, null);
      Navigator.of(context, rootNavigator: true)
          .push(MaterialPageRoute(
            builder: (_) => MobileChatRoute(peerId: card.peerId!),
          ))
          .then((_) {
        if (mounted) {
          ref.read(selectedPeerProvider.notifier).state = null;
        }
      });
    } else if (card.serverId != null && card.channelId != null) {
      ChannelListNotifier.fetchChannels(card.serverId!).then((channels) async {
        final layout =
            await ChannelLayoutNotifier.fetchLayout(card.serverId!);
        if (!mounted) return;
        ref.read(channelListProvider.notifier).setChannels(channels);
        ref.read(channelLayoutProvider.notifier).setLayout(layout);
        ref.read(selectedChannelProvider.notifier).state = card.channelId;
        ref.read(selectedServerProvider.notifier).state = card.serverId;
        ref.read(selectedPeerProvider.notifier).state = null;

        Navigator.of(context, rootNavigator: true)
            .push(MaterialPageRoute(
              builder: (_) => MobileChatRoute(
                serverId: card.serverId!,
                channelId: card.channelId!,
              ),
            ))
            .then((_) {
          if (mounted) {
            ref.read(selectedServerProvider.notifier).state = null;
            ref.read(selectedChannelProvider.notifier).state = null;
          }
        });
      });
    }

    _currentCard = null;
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final cards = ref.watch(systemNotificationProvider);
    final currentPeer = ref.watch(selectedPeerProvider);
    final currentServer = ref.watch(selectedServerProvider);
    final currentChannel = ref.watch(selectedChannelProvider);

    // Find a card that's not for the currently viewed conversation.
    NotificationCard? relevantCard;
    for (final card in cards) {
      if (card.isDm && card.peerId == currentPeer) continue;
      if (!card.isDm &&
          card.serverId == currentServer &&
          card.channelId == currentChannel) {
        continue;
      }
      relevantCard = card;
      break;
    }

    if (relevantCard != null) {
      if (_currentCard?.sourceKey != relevantCard.sourceKey) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _show(relevantCard!);
          }
        });
      } else if (relevantCard.messages.length != _lastMessageCount) {
        _lastMessageCount = relevantCard.messages.length;
        _startDismissTimer();
      }
    }

    final card = _currentCard ?? relevantCard;
    if (card == null) return const SizedBox.shrink();

    final lastMsg = card.messages.isNotEmpty ? card.messages.last : null;

    return Positioned(
      top: 0,
      left: HollowSpacing.md,
      right: HollowSpacing.md,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _opacity,
          child: GestureDetector(
            onTap: _onTap,
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity != null &&
                  details.primaryVelocity! < -100) {
                _dismiss();
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
                vertical: HollowSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.97),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.2),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  HollowAvatar(peerId: card.avatarId, size: 32),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          card.title,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (lastMsg != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            card.isDm
                                ? lastMsg.text
                                : '${lastMsg.senderName}: ${lastMsg.text}',
                            style: HollowTypography.body.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
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
