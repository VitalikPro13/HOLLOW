import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows a dialog to create a new channel in a server.
///
/// [onCreated] receives the NEW channel's id, so a caller can place it in the
/// layout rather than letting it land unsorted at the bottom.
void showCreateChannelDialog(
  BuildContext context,
  String serverId, {
  void Function(String channelId)? onCreated,
}) {
  showHollowDialog(
    context: context,
    builder: (_) =>
        _CreateChannelDialog(serverId: serverId, onCreated: onCreated),
  );
}

class _CreateChannelDialog extends StatefulWidget {
  final String serverId;
  final void Function(String channelId)? onCreated;

  const _CreateChannelDialog({required this.serverId, this.onCreated});

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog>
    with HollowDialogAction {
  final _name = TextEditingController();
  var _isVoice = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSubmit => _name.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || actionRunning) return;
    late final String channelId;
    final ok = await runDialogAction(
      () async => channelId = await crdt_api.createChannel(
        serverId: widget.serverId,
        name: name,
        category: null,
        channelType: _isVoice ? 'voice' : 'text',
      ),
      fallback: "Couldn't create the channel. Try again.",
    );
    if (!ok || !mounted) return;
    Navigator.of(context).pop();
    widget.onCreated?.call(channelId);
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Create channel',
      width: 420,
      busy: actionRunning,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowDialogText(
            'Choose a type and name for your new channel.',
          ),
          const SizedBox(height: HollowSpacing.lg),
          Row(
            children: [
              Expanded(
                child: HollowChip(
                  expand: true,
                  icon: LucideIcons.hash,
                  label: 'Text',
                  selected: !_isVoice,
                  onTap: () => setState(() => _isVoice = false),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: HollowChip(
                  expand: true,
                  icon: LucideIcons.volume2,
                  label: 'Voice',
                  selected: _isVoice,
                  onTap: () => setState(() => _isVoice = true),
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: _name,
            hintText: _isVoice ? 'General' : 'general',
            autofocus: true,
            prefixIcon: Icon(_isVoice ? LucideIcons.volume2 : LucideIcons.hash),
            // The failure is the name's: it sits on the field, text kept.
            errorText: actionError,
            onChanged: (_) => setState(() => actionError = null),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _canSubmit ? _submit : null,
          loading: actionRunning,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
