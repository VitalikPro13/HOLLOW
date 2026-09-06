import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/services/channel_topic_service.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

/// The ONLY mobile in-app notification, mounted inside [MobileChatRoute] so a
/// message arriving in ANOTHER conversation still surfaces. Outside a chat
/// route mobile relies on OS notifications instead, and deliberately shows no
/// in-app banner.
class MobileInChatBanner extends ConsumerStatefulWidget {
  /// The conversation open in this route; its own banners are suppressed.
  final String? currentPeerId;
  final String? currentServerId;
  final String? currentChannelId;

  /// Top offset the caller sizes to clear the chat header and status strips.
  final double topOffset;

  const MobileInChatBanner({
    super.key,
    this.currentPeerId,
    this.currentServerId,
    this.currentChannelId,
    this.topOffset = 8,
  });

  @override
  ConsumerState<MobileInChatBanner> createState() =>
      _MobileInChatBannerState();
}

class _MobileInChatBannerState extends ConsumerState<MobileInChatBanner>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slide;
  late final Animation<double> _opacity;
  // Drives the countdown ring and the auto-dismiss it completes into.
  late final AnimationController _countdown;
  static const int _countdownSeconds = 5;

  /// A card only surfaces if its newest message is at most this old. Cards are
  /// created while no banner is mounted, so without the window an old
  /// notification replays the moment the user enters any chat.
  static const Duration _freshnessWindow = Duration(seconds: 10);

  NotificationCard? _currentCard;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 280),
      reverseDuration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 180),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _countdown = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _countdownSeconds),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _dismiss();
      });
  }

  @override
  void dispose() {
    // A card still on screen has been seen, so it is dropped rather than
    // replayed in the next chat. Post-frame, because providers must not be
    // mutated while the tree is locked for dismantling.
    final shownKey = _currentCard?.sourceKey;
    if (shownKey != null) {
      final notifier = ref.read(systemNotificationProvider.notifier);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => notifier.dismissCard(shownKey));
    }
    _controller.dispose();
    _countdown.dispose();
    super.dispose();
  }

  void _show(NotificationCard card) {
    _currentCard = card;
    _lastMessageCount = card.messages.length;
    _controller.forward();
    _startDismissTimer();
  }

  void _startDismissTimer() {
    _countdown
      ..reset()
      ..forward();
  }

  void _dismiss() {
    _countdown.stop();
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
    _countdown.stop();
    ref.read(systemNotificationProvider.notifier).dismissCard(card.sourceKey);

    // A plain push would stack chats without bound as banners ping-pong between
    // conversations. The new selection is written FIRST so the popped route's
    // guarded cleanup no-ops, then the chat routes pop, then the new one
    // pushes. The container is captured now because this banner dies with its
    // route, leaving `ref` unusable by the time the pushed route pops.
    final nav = Navigator.of(context, rootNavigator: true);
    final container = ProviderScope.containerOf(context, listen: false);

    if (card.isDm && card.peerId != null) {
      final peerId = card.peerId!;
      if (peerId != widget.currentPeerId) {
        ref.read(selectedPeerProvider.notifier).state = peerId;
        ref.read(selectedServerProvider.notifier).state = null;
        ref.read(unreadProvider.notifier).markDmSeen(peerId, null);
        nav.popUntil(
            (r) => r.settings.name != MobileChatRoute.routeName || r.isFirst);
        nav
            .push(hollowMobileRoute(
          settings: const RouteSettings(name: MobileChatRoute.routeName),
          builder: (_) => MobileChatRoute(peerId: peerId),
        ))
            .then((_) {
          // A later banner tap may have replaced this chat already.
          if (container.read(selectedPeerProvider) == peerId) {
            container.read(selectedPeerProvider.notifier).state = null;
          }
        });
      }
    } else if (card.serverId != null && card.channelId != null) {
      final serverId = card.serverId!;
      final channelId = card.channelId!;
      final alreadyHere = serverId == widget.currentServerId &&
          channelId == widget.currentChannelId;
      if (!alreadyHere) {
        ChannelListNotifier.fetchChannels(serverId).then((channels) async {
          final layout = await ChannelLayoutNotifier.fetchLayout(serverId);
          if (!mounted) return;
          ref.read(channelListProvider.notifier).setChannels(channels);
          ref.read(channelLayoutProvider.notifier)
              .setLayout(layout, serverId: serverId);
          ref.read(selectedChannelProvider.notifier).state = channelId;
          ref.read(selectedServerProvider.notifier).state = serverId;
          ref.read(selectedPeerProvider.notifier).state = null;
          // The relay only routes a topic message to subscribed sockets, so
          // without this the freshly opened channel gets no live broadcasts.
          // The helper never throws and retries until the node is up.
          subscribeChannelTopics(serverId: serverId, channelIds: [channelId]);
          final channelName = channels[channelId]?.name ?? '';
          nav.popUntil(
              (r) => r.settings.name != MobileChatRoute.routeName || r.isFirst);
          nav
              .push(hollowMobileRoute(
            settings: const RouteSettings(name: MobileChatRoute.routeName),
            builder: (_) => MobileChatRoute(
              serverId: serverId,
              channelId: channelId,
              channelName: channelName.isNotEmpty ? channelName : 'channel',
            ),
          ))
              .then((_) {
            if (container.read(selectedChannelProvider) == channelId) {
              container.read(selectedServerProvider.notifier).state = null;
              container.read(selectedChannelProvider.notifier).state = null;
            }
          });
        });
      }
    }

    _currentCard = null;
    _controller.reverse();
  }

  bool _isCurrentConversation(NotificationCard card) {
    if (card.isDm) return card.peerId == widget.currentPeerId;
    return card.serverId == widget.currentServerId &&
        card.channelId == widget.currentChannelId;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final cards = ref.watch(systemNotificationProvider);

    // The newest FRESH card that is not the conversation being read. Stale
    // cards are pruned rather than shown.
    final now = DateTime.now();
    NotificationCard? relevantCard;
    final staleKeys = <String>[];
    for (final card in cards.reversed) {
      if (_isCurrentConversation(card)) {
        // Never show this one, here or after they leave, so drop it rather
        // than skip it.
        staleKeys.add(card.sourceKey);
        continue;
      }
      final lastMessageAt =
          card.messages.isNotEmpty ? card.messages.last.timestamp : card.createdAt;
      if (now.difference(lastMessageAt) > _freshnessWindow) {
        // `_dismiss` owns the card being displayed.
        if (card.sourceKey != _currentCard?.sourceKey) {
          staleKeys.add(card.sourceKey);
        }
        continue;
      }
      relevantCard ??= card;
    }
    if (staleKeys.isNotEmpty) {
      final notifier = ref.read(systemNotificationProvider.notifier);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final key in staleKeys) {
          notifier.dismissCard(key);
        }
      });
    }

    if (relevantCard != null) {
      if (_currentCard?.sourceKey != relevantCard.sourceKey) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _show(relevantCard!);
        });
      } else if (relevantCard.messages.length != _lastMessageCount) {
        // `_currentCard` is an immutable snapshot with the shorter list, so the
        // fresh card is adopted and the timer restarted.
        _currentCard = relevantCard;
        _lastMessageCount = relevantCard.messages.length;
        _startDismissTimer();
      }
    }

    final card = (relevantCard != null &&
            relevantCard.sourceKey == _currentCard?.sourceKey)
        ? relevantCard
        : (_currentCard ?? relevantCard);
    if (card == null) return const SizedBox.shrink();

    // Kept short so the banner does not clutter the chat below.
    final msgs = card.messages.length > 3
        ? card.messages.sublist(card.messages.length - 3)
        : card.messages;
    final msgStyle = HollowTypography.body.copyWith(
      color: hollow.textSecondary,
      fontSize: 12,
    );

    return Positioned(
      top: widget.topOffset,
      left: HollowSpacing.sm,
      right: HollowSpacing.sm,
      // A Material ancestor, or the Text widgets get the yellow debug
      // double-underline: nothing else sits between this Stack child and them.
      child: Material(
        type: MaterialType.transparency,
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _opacity,
            child: GestureDetector(
              onTap: _onTap,
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) < -100) _dismiss();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm + 2,
                  vertical: HollowSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: hollow.elevated.withValues(alpha: 0.98),
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border:
                      Border.all(color: hollow.accent.withValues(alpha: 0.25)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    HollowAvatar(peerId: card.avatarId, size: 28),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      // A token from a chat the user does not have open may not
                      // have its bytes cached yet.
                      child: EmoteScope(
                        serverId: card.serverId,
                        peerHint: card.peerId,
                        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            card.title,
                            style: HollowTypography.body.copyWith(
                              color: hollow.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          for (final m in msgs)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              // Or emote tokens render as their raw
                              // [e:name:hash] form.
                              child: Text.rich(
                                TextSpan(
                                  style: msgStyle,
                                  children: [
                                    if (!card.isDm)
                                      TextSpan(
                                          text: '${m.senderName}: '),
                                    ...emotePreviewSpans(m.text, msgStyle),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        ),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    _CountdownRing(
                      controller: _countdown,
                      totalSeconds: _countdownSeconds,
                      color: hollow.accent,
                      trackColor: hollow.border,
                      textColor: hollow.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A depleting ring with the remaining whole seconds in the centre.
class _CountdownRing extends StatelessWidget {
  final AnimationController controller;
  final int totalSeconds;
  final Color color;
  final Color trackColor;
  final Color textColor;

  const _CountdownRing({
    required this.controller,
    required this.totalSeconds,
    required this.color,
    required this.trackColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          // `controller.value` runs 0 to 1 as time elapses, so the seconds
          // left count down against it.
          final left = (totalSeconds * (1.0 - controller.value))
              .ceil()
              .clamp(1, totalSeconds);
          return Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  value: controller.value,
                  strokeWidth: 2.5,
                  backgroundColor: trackColor.withValues(alpha: 0.4),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              Text(
                '$left',
                style: HollowTypography.caption.copyWith(
                  color: textColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
