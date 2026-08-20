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

/// Compact in-app banner — the ONLY mobile in-app notification. Shown WHILE the
/// user is sitting inside a chat route, mounted inside [MobileChatRoute], so a
/// message arriving in ANOTHER conversation still surfaces. Outside a chat there
/// is no in-app banner (mobile relies on OS notifications then). Deliberately
/// small (single card, last 3 lines, a countdown ring, anchored just below the
/// chat header) so it doesn't cover the conversation. Tap opens, swipe-up or the
/// 5s countdown dismisses.
class MobileInChatBanner extends ConsumerStatefulWidget {
  /// The conversation currently open in this route — banners for it are
  /// suppressed (the user is already reading it).
  final String? currentPeerId;
  final String? currentServerId;
  final String? currentChannelId;

  /// Top offset (below the header). The caller passes a value that clears the
  /// chat header + any status strips.
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
  // Drives the 5s countdown ring (and the auto-dismiss when it completes).
  late final AnimationController _countdown;
  static const int _countdownSeconds = 5;

  /// A card only surfaces here if its newest message is at most this old.
  /// Cards can be created while NO banner is mounted (user sitting on a main
  /// tab — there is deliberately no banner outside chat routes), so without
  /// this window an old notification would replay the moment the user enters
  /// any chat. Unread badges already carry the stale signal.
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
    // The banner leaves with its route. If a card is still on screen the user
    // has seen it — drop it from the provider so it doesn't replay in the
    // next chat they open. (Post-frame: providers must not be mutated while
    // the tree is locked for dismantling.)
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

    // This banner only ever shows INSIDE a chat route, so a plain push would
    // stack the new chat on top of the current one (and ping-ponging between
    // two conversations via banners grew the stack unboundedly). Instead:
    // write the new selection FIRST (so the popped route's guarded cleanup
    // no-ops), then pop every chat route off the top, then push the new one.
    //
    // The container is captured now — this banner dies with the route it sits
    // in, so `ref` is unusable by the time the pushed route pops.
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
          // Guarded: only clear if this chat is still the selected one — a
          // later banner tap may have replaced it already.
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
          // Subscribe the relay topic — without this the freshly opened
          // channel receives NO live topic broadcasts (the relay only routes
          // a topic message to subscribed sockets). Node-safe helper: never
          // throws, retries if the node isn't running yet.
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

    // Pick the newest FRESH card that's NOT the conversation we're currently
    // reading (cards are appended in arrival order — iterate newest-first).
    // Stale cards (queued while no banner was mounted, or left behind by a
    // popped route) are pruned instead of shown.
    final now = DateTime.now();
    NotificationCard? relevantCard;
    final staleKeys = <String>[];
    for (final card in cards.reversed) {
      if (_isCurrentConversation(card)) {
        // The user is reading this conversation — the card must never show,
        // here or after they leave. Drop it instead of just skipping it.
        staleKeys.add(card.sourceKey);
        continue;
      }
      final lastMessageAt =
          card.messages.isNotEmpty ? card.messages.last.timestamp : card.createdAt;
      if (now.difference(lastMessageAt) > _freshnessWindow) {
        // Don't prune the card we're actively displaying — _dismiss owns it.
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
        // Same conversation got more messages — adopt the FRESH card (the old
        // _currentCard is an immutable snapshot with the old, shorter list) and
        // restart the timer so the accumulated stack shows + stays a bit longer.
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

    // Last 3 messages (compact — don't clutter the chat below).
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
      // Material ancestor so the Text widgets don't get the yellow debug
      // double-underline (this banner is a Positioned child of a Stack with no
      // Material between it and the Text).
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
                      // Emote pull context for the previews — a token from a
                      // chat the user doesn't have open may not have its
                      // bytes cached yet.
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
                              // Text.rich so emote tokens render as inline
                              // images instead of the raw [e:name:hash] form.
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

/// Small circular countdown shown in the banner's right space: a depleting ring
/// + the remaining whole seconds (5→1) in the center.
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
          // controller.value runs 0→1 over the countdown. Whole seconds left
          // count 5→1; the ring fills as time elapses (value 0→1).
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
