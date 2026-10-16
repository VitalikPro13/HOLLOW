import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// The server setting Rust reads for text chat in voice rooms (#107).
const String kVoiceTextChatKey = 'voice_text_chat';

/// A voice channel's own choice, as `ChannelInfo.voiceChat` holds it.
const List<(String, String)> kVoiceChatModes = [
  ('server', 'Server setting'),
  ('on', 'On'),
  ('off', 'Off'),
];

/// The server-wide switch for text chat in voice rooms, on by default. Each
/// voice room can override it in its own settings.
class VoiceRoomsChatSection extends ConsumerStatefulWidget {
  final String serverId;
  const VoiceRoomsChatSection({super.key, required this.serverId});

  @override
  ConsumerState<VoiceRoomsChatSection> createState() =>
      _VoiceRoomsChatSectionState();
}

class _VoiceRoomsChatSectionState extends ConsumerState<VoiceRoomsChatSection> {
  /// What the switch shows after a change, until the page is rebuilt from the
  /// saved value: a read right after the write still sees the old one.
  bool? _shown;

  Future<void> _set(bool on) async {
    final before = _shown;
    setState(() => _shown = on);
    try {
      await crdt_api.updateServerSetting(
          serverId: widget.serverId,
          key: kVoiceTextChatKey,
          value: on ? 'true' : 'false');
    } catch (e) {
      if (!mounted) return;
      setState(() => _shown = before);
      HollowToast.show(
          context, friendlyError(e, fallback: "Couldn't save that. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(serverSettingProvider(
        (serverId: widget.serverId, key: kVoiceTextChatKey)));
    // Showing the default before the saved value loads flips the switch on
    // screen for a frame.
    if (_shown == null && !saved.hasValue) return const SizedBox.shrink();
    final value = _shown ?? (saved.valueOrNull ?? '') != 'false';
    return SettingsSection(
      title: 'Voice rooms',
      children: [
        SettingsSwitchRow(
          title: 'Text chat in voice rooms',
          subtitle: 'A chat sits beside every voice room. Each room can still '
              'turn its own on or off.',
          value: value,
          onChanged: saved.hasValue ? _set : null,
        ),
      ],
    );
  }
}
