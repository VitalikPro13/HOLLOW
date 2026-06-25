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

    if (card.isDm && card.peerId != null) {
      ref.read(selectedPeerProvider.notifier).state = card.peerId;
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(unreadProvider.notifier).markDmSeen(card.peerId!, null);
      Navigator.of(context, rootNavigator: true).push(hollowMobileRoute(
        builder: (_) => MobileChatRoute(peerId: card.peerId!),
      ));
    } else if (card.serverId != null && card.channelId != null) {
      ChannelListNotifier.fetchChannels(card.serverId!).then((channels) async {
        final layout = await ChannelLayoutNotifier.fetchLayout(card.serverId!);
        if (!mounted) return;
        ref.read(channelListProvider.notifier).setChannels(channels);
        ref.read(channelLayoutProvider.notifier).setLayout(layout);
        ref.read(selectedChannelProvider.notifier).state = card.channelId;
        ref.read(selectedServerProvider.notifier).state = card.serverId;
        ref.read(selectedPeerProvider.notifier).state = null;
        Navigator.of(context, rootNavigator: true).push(hollowMobileRoute(
          builder: (_) => MobileChatRoute(
            serverId: card.serverId!,
            channelId: card.channelId!,
          ),
        ));
      });
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

    // Pick the newest card that's NOT the conversation we're currently reading.
    NotificationCard? relevantCard;
    for (final card in cards) {
      if (_isCurrentConversation(card)) continue;
      relevantCard = card;
      break;
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
                              child: Text(
                                card.isDm
                                    ? m.text
                                    : '${m.senderName}: ${m.text}',
                                style: HollowTypography.body.copyWith(
                                  color: hollow.textSecondary,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
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
