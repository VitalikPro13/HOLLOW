import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/channel_chat_provider.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/member_panel_provider.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/chat/channel_message_bubble.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons/lucide_icons.dart';

class ChannelChatPane extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const ChannelChatPane({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
  });

  @override
  ConsumerState<ChannelChatPane> createState() => _ChannelChatPaneState();
}

class _ChannelChatPaneState extends ConsumerState<ChannelChatPane> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _historyLoaded = false;
  int _previousMessageCount = 0;

  String get _stateKey => '${widget.serverId}:${widget.channelId}';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref
        .read(channelChatProvider.notifier)
        .loadHistory(widget.serverId, widget.channelId);
    _scrollToBottom();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await ref
        .read(channelChatProvider.notifier)
        .sendMessage(widget.serverId, widget.channelId, text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final chatState = ref.watch(channelChatProvider);
    final messages = chatState[_stateKey] ?? [];

    // Auto-scroll when new messages arrive and user is near the bottom.
    if (messages.length > _previousMessageCount && _isNearBottom) {
      _scrollToBottom();
    }
    _previousMessageCount = messages.length;

    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(bottom: BorderSide(color: haven.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.hash, size: 20, color: haven.textSecondary),
              const SizedBox(width: HavenSpacing.sm),
              Text(
                widget.channelName,
                style: HavenTypography.subheading.copyWith(
                  color: haven.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: HavenSpacing.md),
              Icon(LucideIcons.lock, size: 14, color: haven.success),
              const SizedBox(width: HavenSpacing.xs),
              Text(
                'E2E Encrypted',
                style:
                    HavenTypography.caption.copyWith(color: haven.success),
              ),
              const SizedBox(width: HavenSpacing.md),
              _ConnectionIndicator(
                serverId: widget.serverId,
                channelId: widget.channelId,
              ),
              const Spacer(),
              HavenTooltip(
                message: 'Toggle member panel',
                child: HavenPressable(
                  onTap: () => ref.read(memberPanelProvider.notifier).state =
                      !ref.read(memberPanelProvider),
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    LucideIcons.users,
                    size: 20,
                    color: ref.watch(memberPanelProvider)
                        ? haven.accent
                        : haven.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Messages list
        Expanded(
          child: Container(
            color: haven.background,
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.hash,
                          size: 64,
                          color:
                              haven.textSecondary.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: HavenSpacing.lg),
                        Text(
                          'Welcome to #${widget.channelName}',
                          style: HavenTypography.heading
                              .copyWith(color: haven.textPrimary),
                        ),
                        const SizedBox(height: HavenSpacing.sm),
                        Text(
                          'This is the beginning of the channel.',
                          style: HavenTypography.body
                              .copyWith(color: haven.textSecondary),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(HavenSpacing.md),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      return ChannelMessageBubble(
                          message: messages[index]);
                    },
                  ),
          ),
        ),

        // Input bar
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.md,
            vertical: HavenSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(top: BorderSide(color: haven.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: HavenTextField(
                  controller: _controller,
                  hintText: 'Message #${widget.channelName}',
                  style: HavenTypography.body
                      .copyWith(color: haven.textPrimary),
                  borderRadius: haven.radiusLg,
                  onSubmitted: (_) => _handleSend(),
                ),
              ),
              const SizedBox(width: HavenSpacing.sm),
              HavenPressable(
                onTap: _handleSend,
                borderRadius: BorderRadius.circular(haven.radiusMd),
                backgroundColor: haven.accent,
                padding: const EdgeInsets.all(HavenSpacing.sm),
                child: Icon(
                  LucideIcons.send,
                  color: haven.textOnAccent,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shows how many server members are currently connected + sync status.
class _ConnectionIndicator extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  const _ConnectionIndicator({
    required this.serverId,
    required this.channelId,
  });

  @override
  ConsumerState<_ConnectionIndicator> createState() =>
      _ConnectionIndicatorState();
}

class _ConnectionIndicatorState extends ConsumerState<_ConnectionIndicator> {
  DateTime? _lastRetry;

  void _retry() {
    final now = DateTime.now();
    if (_lastRetry != null &&
        now.difference(_lastRetry!).inSeconds < 3) {
      return; // 3s debounce
    }
    _lastRetry = now;
    try {
      network_api.requestChannelSync(
        serverId: widget.serverId,
        channelId: widget.channelId,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final connectedPeers = ref.watch(peersProvider);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final localPeerId = ref.watch(identityProvider).peerId;
    final syncStatus = ref.watch(serverSyncStatusProvider(widget.serverId));

    return membersAsync.when(
      data: (members) {
        final otherMembers =
            members.where((m) => m.peerId != localPeerId).toList();
        if (otherMembers.isEmpty) return const SizedBox.shrink();

        final onlineCount = otherMembers
            .where((m) => connectedPeers.containsKey(m.peerId))
            .length;
        final totalOthers = otherMembers.length;
        final allOnline = onlineCount == totalOthers;

        final connColor = onlineCount == 0
            ? haven.error
            : allOnline
                ? haven.success
                : haven.warning;

        // Derive effective status — show "Connecting..." when idle + no peers online.
        final effectiveStatus = syncStatus == ServerSyncStatus.idle &&
                onlineCount == 0
            ? ServerSyncStatus.connecting
            : syncStatus;

        // Sync/connection state display.
        final bool showStatus = effectiveStatus != ServerSyncStatus.idle;
        final Color dotColor;
        final bool pulse;
        final String label;
        final bool showRetry;

        switch (effectiveStatus) {
          case ServerSyncStatus.connecting:
            dotColor = haven.textSecondary;
            pulse = true;
            label = 'Connecting...';
            showRetry = false;
          case ServerSyncStatus.syncing:
            dotColor = haven.accent;
            pulse = true;
            label = 'Syncing...';
            showRetry = false;
          case ServerSyncStatus.synced:
            dotColor = haven.success;
            pulse = false;
            label = 'Synced';
            showRetry = false;
          case ServerSyncStatus.retrying:
            dotColor = haven.warning;
            pulse = true;
            label = 'Retrying...';
            showRetry = false;
          case ServerSyncStatus.failed:
            dotColor = haven.error;
            pulse = false;
            label = 'Sync failed';
            showRetry = true;
          case ServerSyncStatus.idle:
            dotColor = connColor;
            pulse = false;
            label = '$onlineCount/$totalOthers';
            showRetry = false;
        }

        final connTooltip =
            '$onlineCount of $totalOthers member${totalOthers == 1 ? '' : 's'} online';

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sync status (shown when not idle).
            if (showStatus) ...[
              HavenTooltip(
                message: label,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusDot(color: dotColor, pulse: pulse),
                    const SizedBox(width: HavenSpacing.xs),
                    Text(
                      label,
                      style:
                          HavenTypography.caption.copyWith(color: dotColor),
                    ),
                    if (showRetry) ...[
                      const SizedBox(width: HavenSpacing.xs),
                      GestureDetector(
                        onTap: _retry,
                        child: Icon(
                          LucideIcons.refreshCw,
                          size: 12,
                          color: haven.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: HavenSpacing.sm),
            ],
            // Connection count (always shown).
            HavenTooltip(
              message: connTooltip,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(color: connColor),
                  const SizedBox(width: HavenSpacing.xs),
                  Text(
                    '$onlineCount/$totalOthers',
                    style:
                        HavenTypography.caption.copyWith(color: connColor),
                  ),
                ],
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}
