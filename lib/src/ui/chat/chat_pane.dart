import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/chat_provider.dart';
import 'package:haven/src/core/providers/member_panel_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/chat/message_bubble.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

class ChatPane extends ConsumerStatefulWidget {
  final String peerId;
  final bool isEncrypted;

  const ChatPane({
    super.key,
    required this.peerId,
    required this.isEncrypted,
  });

  @override
  ConsumerState<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<ChatPane> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _historyLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref.read(chatProvider.notifier).loadHistory(widget.peerId);
    _scrollToBottom();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
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
    await ref.read(chatProvider.notifier).sendMessage(widget.peerId, text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final chatHistory = ref.watch(chatProvider);
    final messages = chatHistory[widget.peerId] ?? [];

    return Column(
      children: [
        // Peer ID header
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.lg,
            vertical: HavenSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(
              bottom: BorderSide(color: haven.border),
            ),
          ),
          child: Row(
            children: [
              HavenAvatar(peerId: widget.peerId, size: 28),
              const SizedBox(width: HavenSpacing.sm),
              StatusDot(color: haven.success, size: 8),
              const SizedBox(width: HavenSpacing.sm),
              Expanded(
                child: SelectableText(
                  widget.peerId,
                  style: HavenTypography.mono.copyWith(
                    color: haven.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              if (widget.isEncrypted) ...[
                Icon(
                  LucideIcons.lock,
                  size: 14,
                  color: haven.success,
                ),
                const SizedBox(width: HavenSpacing.xs),
                Text(
                  'Encrypted',
                  style: HavenTypography.caption.copyWith(
                    color: haven.success,
                  ),
                ),
                const SizedBox(width: HavenSpacing.sm),
              ],
              HavenTooltip(
                message: 'Copy peer ID',
                child: HavenPressable(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.peerId));
                    HavenToast.show(
                      context,
                      'Peer ID copied',
                      type: HavenToastType.success,
                      duration: const Duration(seconds: 1),
                    );
                  },
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(LucideIcons.copy, size: 16, color: haven.textSecondary),
                ),
              ),
              const SizedBox(width: HavenSpacing.xs),
              HavenTooltip(
                message: 'Toggle member panel',
                child: HavenPressable(
                  onTap: () {
                    ref.read(memberPanelProvider.notifier).state =
                        !ref.read(memberPanelProvider);
                  },
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    LucideIcons.users,
                    size: 18,
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
                          LucideIcons.messageCircle,
                          size: 48,
                          color: haven.textSecondary.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: HavenSpacing.md),
                        Text(
                          'No messages yet. Say hello!',
                          style: HavenTypography.body.copyWith(
                            color: haven.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(HavenSpacing.md),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      return MessageBubble(message: messages[index]);
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
            border: Border(
              top: BorderSide(color: haven.border),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: HavenTextField(
                  controller: _controller,
                  hintText: 'Type a message...',
                  style: HavenTypography.body.copyWith(
                    color: haven.textPrimary,
                  ),
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
