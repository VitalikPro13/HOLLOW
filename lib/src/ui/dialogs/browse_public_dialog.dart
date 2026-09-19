import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';

void showBrowsePublicDialog(BuildContext context, WidgetRef ref) {
  final controller = TextEditingController();

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      return HollowDialog(
        title: 'Browse public channels',
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HollowDialogText(
              'Enter a server invite link or ID to browse its public channels as a guest.',
            ),
            const SizedBox(height: HollowSpacing.lg),
            HollowTextField(
              controller: controller,
              hintText: 'Server ID or invite link',
              autofocus: true,
              onSubmitted: (_) => _browse(dialogContext, ref, controller),
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () => _browse(dialogContext, ref, controller),
            child: const Text('Browse'),
          ),
        ],
      );
    },
  );
}

Future<void> _browse(BuildContext context, WidgetRef ref,
    TextEditingController controller) async {
  final input = controller.text.trim();
  if (input.isEmpty) return;

  // Accepts a hollow:// link, a web /join# link, a raw id, or the legacy
  // fallbacks (a ?server= query, else the last path segment).
  final invite = inviteFromInput(input, HollowLinkType.serverInvite);
  String serverId = invite.id;
  if (serverId == input) {
    final serverParam = Uri.tryParse(input)?.queryParameters['server'];
    if (serverParam != null && serverParam.isNotEmpty) {
      serverId = serverParam;
    } else if (input.contains('/')) {
      serverId = input.split('/').last;
    }
  }

  if (!await ensureRelayForInviteId(context, ref,
      type: HollowLinkType.serverInvite, id: serverId, relay: invite.relay)) {
    return;
  }
  if (!context.mounted) return;

  // Realtime by default, manual once the cap is reached.
  final notifier = ref.read(savedGuestServersProvider.notifier);
  final realtimeCount = notifier.realtimeCount;
  final mode = realtimeCount >= 7
      ? GuestFetchMode.manual
      : GuestFetchMode.realtime;
  notifier.addServer(serverId, '', mode);

  final split = ref.read(splitViewProvider);
  if (split.isSplit) ref.read(splitViewProvider.notifier).closeSplit();
  setShellTab(ref.read, ShellTab.guest);
  ref.read(selectedServerProvider.notifier).state = null;
  ref.read(channelListProvider.notifier).clear();
  ref.read(selectedChannelProvider.notifier).state = null;
  ref.read(selectedPeerProvider.notifier).state = null;
  ref.read(serverSettingsOpenProvider.notifier).state = false;
  ref.read(guestExpandedServerProvider.notifier).state = serverId;
  ref.read(guestSelectedServerProvider.notifier).state = serverId;

  final loading = Set<String>.from(ref.read(guestLoadingProvider));
  loading.add(serverId);
  ref.read(guestLoadingProvider.notifier).state = loading;
  crdt_api.requestPublicChannels(serverId: serverId).catchError((_) {});

  Navigator.pop(context);
}
