import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart' show shouldGroup;
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class GuestChatPane extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;

  const GuestChatPane({
    super.key,
    required this.serverId,
    required this.channelId,
  });

  @override
  ConsumerState<GuestChatPane> createState() => _GuestChatPaneState();
}

class _GuestChatPaneState extends ConsumerState<GuestChatPane> {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  bool _showSearch = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  int _prevMessageCount = 0;

  @override
  void initState() {
    super.initState();
    // Jump to bottom after first messages arrive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    // reverse:true — the newest message is index 0 pinned to the bottom.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: 0, alignment: 0.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final key = '${widget.serverId}:${widget.channelId}';
    final messages =
        ref.watch(channelChatProvider.select((s) => s[key])) ?? [];
    final hasMore = ref.watch(
        guestHasMoreProvider.select((m) => m[key] ?? false));

    // Auto-scroll to bottom when new messages arrive.
    final currentCount = messages.where((m) => m.hiddenAt == null).length;
    if (currentCount > _prevMessageCount && _prevMessageCount > 0) {
      _jumpToBottom();
    }
    _prevMessageCount = currentCount;
    final channelName = ref.watch(guestChannelMapProvider.select((m) =>
        m[widget.serverId]
            ?.where((c) => c.channelId == widget.channelId)
            .firstOrNull
            ?.name ??
        widget.channelId));

    final visible = messages.where((m) => m.hiddenAt == null).toList();
    final filtered = _searchQuery.isEmpty
        ? visible
        : visible
            .where(
                (m) => m.text.toLowerCase().contains(_searchQuery.toLowerCase()))
            .toList();

    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.hash, size: 18, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  channelName,
                  style: TextStyle(
                    color: hollow.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HollowPressable(
                onTap: () {
                  crdt_api.requestPublicChannelSync(
                    serverId: widget.serverId,
                    channelId: widget.channelId,
                  ).catchError((_) {});
                  HollowToast.show(context, 'Refreshing...',
                      type: HollowToastType.info);
                },
                semanticLabel: 'Retry',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(4),
                child:
                    Icon(LucideIcons.refreshCw, size: 15, color: hollow.textSecondary),
              ),
              const SizedBox(width: 4),
              HollowPressable(
                onTap: () => setState(() {
                  _showSearch = !_showSearch;
                  if (!_showSearch) {
                    _searchQuery = '';
                    _searchController.clear();
                  }
                }),
                semanticLabel: 'Search messages',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(4),
                child: Icon(
                  LucideIcons.search,
                  size: 15,
                  color: _showSearch ? hollow.accent : hollow.textSecondary,
                ),
              ),
            ],
          ),
        ),

        // Search field (slide down)
        AnimatedSize(
          duration: HollowDurations.fast,
          curve: HollowCurves.enter,
          child: _showSearch
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.lg,
                    vertical: HollowSpacing.xs,
                  ),
                  child: HollowTextField(
                    controller: _searchController,
                    hintText: 'Search messages...',
                    autofocus: true,
                    isDense: true,
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                )
              : const SizedBox.shrink(),
        ),

        // Message list
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    _searchQuery.isNotEmpty
                        ? 'No matching messages'
                        : 'No messages yet',
                    style: TextStyle(
                      color: hollow.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                )
              : MessageActionBarScope(
                  child: Builder(
                    builder: (scopeContext) =>
                        NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollUpdateNotification) {
                          MessageActionBarScope.of(scopeContext)?.dismissAll();
                        }
                        return false;
                      },
                      child: SelectionArea(
                        contextMenuBuilder: (_, __) =>
                            const SizedBox.shrink(),
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: ScrollablePositionedList.builder(
                            key: ValueKey(
                                'guest-list-${widget.serverId}-${widget.channelId}'),
                            itemScrollController: _itemScrollController,
                            itemPositionsListener: _itemPositionsListener,
                            // reverse:true — newest message at builder index
                            // 0, pinned to the bottom edge; the "Load more"
                            // button becomes the LAST reversed index (the
                            // oldest end = visual top). No sentinel row.
                            reverse: true,
                            initialScrollIndex: 0,
                            initialAlignment: 0.0,
                            padding: const EdgeInsets.symmetric(
                              vertical: HollowSpacing.sm,
                            ),
                            itemCount: filtered.length + (hasMore ? 1 : 0),
                            itemBuilder: (context, revIndex) {
                              // "Load more" button at the visual top.
                              if (hasMore && revIndex == filtered.length) {
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                        HollowSpacing.sm),
                                    child: HollowButton.ghost(
                                      compact: true,
                                      onPressed: () {
                                        final oldest = filtered.first.timestamp;
                                        crdt_api.requestPublicChannelSync(
                                          serverId: widget.serverId,
                                          channelId: widget.channelId,
                                          beforeTimestamp: oldest
                                              .millisecondsSinceEpoch,
                                        ).catchError((_) {});
                                      },
                                      child: const Text('Load more'),
                                    ),
                                  ),
                                );
                              }

                              // Reversed builder index → chronological.
                              final msgIndex =
                                  filtered.length - 1 - revIndex;

                              final msg = filtered[msgIndex];
                              final showHeader = msgIndex == 0 ||
                                  !shouldGroup(
                                    currentIsMe: msg.isMe,
                                    previousIsMe:
                                        filtered[msgIndex - 1].isMe,
                                    currentTime: msg.timestamp,
                                    previousTime:
                                        filtered[msgIndex - 1].timestamp,
                                    currentSenderId: msg.senderId,
                                    previousSenderId:
                                        filtered[msgIndex - 1].senderId,
                                  );

                              return MessageHoverWrapper(
                                isMe: false,
                                messageId: msg.messageId,
                                currentText: msg.text,
                                onCopy: () {
                                  Clipboard.setData(
                                      ClipboardData(text: msg.text));
                                  HollowToast.show(
                                      context, 'Copied to clipboard',
                                      type: HollowToastType.success);
                                },
                                onInfo: () {
                                  showMessageProofDialog(
                                    context,
                                    MessageProofData(
                                      senderPeerId: msg.senderId,
                                      senderDisplayName:
                                          _senderName(msg.senderId),
                                      text: msg.text,
                                      timestampMs:
                                          (msg.editedAt ?? msg.timestamp)
                                              .millisecondsSinceEpoch,
                                      signature: msg.signature,
                                      publicKey: msg.publicKey,
                                      messageId: msg.messageId,
                                      context:
                                          '${widget.serverId}:${widget.channelId}',
                                      msgType: 'ch',
                                      fileAttachment: msg.fileAttachment,
                                    ),
                                  );
                                },
                                child: ChannelMessageBubble(
                                  message: msg,
                                  serverId: widget.serverId,
                                  showHeader: showHeader,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),

        // Guest footer
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.md,
          ),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: hollow.border)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.lock, size: 14, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Join this server to send messages',
                style: TextStyle(
                  color: hollow.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _senderName(String senderId) {
    // Check guest sender profiles first (populated from sync responses)
    final guestProfile = ref.read(guestSenderProfilesProvider)[senderId];
    if (guestProfile != null && guestProfile.name.isNotEmpty) {
      return guestProfile.name;
    }
    // Fall back to regular profiles (for member servers)
    final profiles = ref.read(profileProvider);
    final profile = profiles[senderId];
    return displayNameForPeer(profile, senderId);
  }
}
