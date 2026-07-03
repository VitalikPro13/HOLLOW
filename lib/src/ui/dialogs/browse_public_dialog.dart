import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';

void showBrowsePublicDialog(BuildContext context, WidgetRef ref) {
  final controller = TextEditingController();

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);

      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 420,
              padding: const EdgeInsets.all(HollowSpacing.xl),
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusXl),
                border: Border.all(color: hollow.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Browse Public Channels',
                    style: TextStyle(
                      color: hollow.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  Text(
                    'Enter a server invite link or ID to browse its public channels as a guest.',
                    style: TextStyle(
                      color: hollow.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.lg),
                  HollowTextField(
                    controller: controller,
                    hintText: 'Server ID or invite link',
                    autofocus: true,
                    onSubmitted: (_) =>
                        _browse(dialogContext, ref, controller),
                  ),
                  const SizedBox(height: HollowSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      HollowButton.ghost(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      HollowButton.filled(
                        onPressed: () =>
                            _browse(dialogContext, ref, controller),
                        child: const Text('Browse'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

void _browse(
    BuildContext context, WidgetRef ref, TextEditingController controller) {
  final input = controller.text.trim();
  if (input.isEmpty) return;

  String serverId = input;
  final serverParam = Uri.tryParse(input)?.queryParameters['server'];
  if (serverParam != null && serverParam.isNotEmpty) {
    serverId = serverParam;
  } else if (input.contains('/')) {
    serverId = input.split('/').last;
  }

  // Add to saved servers (default realtime, or manual if cap reached).
  final notifier = ref.read(savedGuestServersProvider.notifier);
  final realtimeCount = notifier.realtimeCount;
  final mode = realtimeCount >= 7
      ? GuestFetchMode.manual
      : GuestFetchMode.realtime;
  notifier.addServer(serverId, '', mode);

  // Open the guest panel and expand this server.
  final split = ref.read(splitViewProvider);
  if (split.isSplit) ref.read(splitViewProvider.notifier).closeSplit();
  ref.read(guestTabOpenProvider.notifier).state = true;
  ref.read(shareTabOpenProvider.notifier).state = false;
  ref.read(archiveTabOpenProvider.notifier).state = false;
  ref.read(selectedServerProvider.notifier).state = null;
  ref.read(channelListProvider.notifier).clear();
  ref.read(selectedChannelProvider.notifier).state = null;
  ref.read(selectedPeerProvider.notifier).state = null;
  ref.read(serverSettingsOpenProvider.notifier).state = false;
  ref.read(guestExpandedServerProvider.notifier).state = serverId;
  ref.read(guestSelectedServerProvider.notifier).state = serverId;

  // Request channels.
  final loading = Set<String>.from(ref.read(guestLoadingProvider));
  loading.add(serverId);
  ref.read(guestLoadingProvider.notifier).state = loading;
  crdt_api.requestPublicChannels(serverId: serverId).catchError((_) {});

  Navigator.pop(context);
}
