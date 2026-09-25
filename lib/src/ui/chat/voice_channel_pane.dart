import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The voice room's chat is in the side panel. Session-sticky, on by default.
final vcChatPanelOpenProvider = StateProvider<bool>((_) => true);

/// Width of the chat panel beside a voice room's stage.
const double kVcChatPanelWidth = 300;

/// A voice channel (D3): the room you are in is always the stage, a room you
/// are not in shows who is there with Join voice, and the channel's chat sits
/// in the one side panel.
class VoiceChannelPane extends ConsumerWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const VoiceChannelPane({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final joined = ref.watch(voiceChannelProvider.select((s) =>
        s.currentServerId == serverId && s.currentChannelId == channelId));
    final chatOpen = ref.watch(vcChatPanelOpenProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            children: [
              _StageHeader(
                serverId: serverId,
                channelId: channelId,
                channelName: channelName,
              ),
              Expanded(
                child: joined
                    ? CallStage(
                        source: VcCallStageSource(
                            serverId: serverId, channelId: channelId),
                      )
                    : _RoomPreview(serverId: serverId, channelId: channelId),
              ),
            ],
          ),
        ),
        if (chatOpen)
          Container(
            width: kVcChatPanelWidth,
            decoration: BoxDecoration(
              color: hollow.surface,
              border: Border(left: BorderSide(color: hollow.border)),
            ),
            child: ChannelChatPane(
              serverId: serverId,
              channelId: channelId,
              channelName: channelName,
              headerTitle: 'Chat',
              isVoice: true,
            ),
          ),
      ],
    );
  }
}

/// The room's name, how many are in it, and the Chat toggle.
class _StageHeader extends ConsumerWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const _StageHeader({
    required this.serverId,
    required this.channelId,
    required this.channelName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final count = ref.watch(voiceChannelProvider
        .select((s) => s.getParticipants(serverId, channelId).length));
    final chatOpen = ref.watch(vcChatPanelOpenProvider);
    return Container(
      height: kChatHeaderHeight,
      padding: const EdgeInsets.only(
        left: HollowSpacing.lg,
        right: HollowSpacing.md,
      ),
      decoration: BoxDecoration(
        color: hollow.background,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.volume2, size: 20, color: hollow.textTertiary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    channelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.subheading
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    count == 1 ? '1 person' : '$count people',
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textTertiary),
                  ),
                ],
              ],
            ),
          ),
          HollowIconButton(
            icon: LucideIcons.messageSquare,
            label: chatOpen ? 'Hide the chat' : 'Show the chat',
            selected: chatOpen,
            onPressed: () =>
                ref.read(vcChatPanelOpenProvider.notifier).state = !chatOpen,
          ),
        ],
      ),
    );
  }
}

/// Nobody speaks in a room we are not in, as far as this device knows.
final _silent = Provider<bool>((_) => false);

/// A room you are not in: who is there, and one Join voice.
class _RoomPreview extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;

  const _RoomPreview({required this.serverId, required this.channelId});

  @override
  ConsumerState<_RoomPreview> createState() => _RoomPreviewState();
}

class _RoomPreviewState extends ConsumerState<_RoomPreview> {
  bool _joining = false;

  Future<void> _join() async {
    setState(() => _joining = true);
    try {
      await ref
          .read(voiceChannelProvider.notifier)
          .joinChannel(widget.serverId, widget.channelId);
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, "Couldn't join the voice room",
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final here = ref.watch(voiceChannelProvider
        .select((s) => s.getParticipants(widget.serverId, widget.channelId)));
    final links = ref.watch(deviceLinkProvider);
    final profiles = ref.watch(profileProvider);
    final join = HollowButton.filled(
      icon: const Icon(LucideIcons.phone, size: 14),
      loading: _joining,
      onPressed: _join,
      child: const Text('Join voice'),
    );

    if (here.isEmpty) {
      return ColoredBox(
        color: hollow.background,
        child: HollowEmptyState(
          glyph: LucideIcons.volume2,
          title: "Nobody's here yet",
          action: join,
        ),
      );
    }
    return ColoredBox(
      color: hollow.background,
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.lg),
        child: StageGrid(
          footer: join,
          tiles: [
            for (final p in here)
              CallPersonTile(
                key: ValueKey('preview:$p'),
                size: CallTileSize.large,
                person: CallPerson(
                  id: p,
                  master: links.identityOf(p),
                  isSelf: false,
                  name: displayNameFor(profiles, links.identityOf(p)),
                  speaking: _silent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
